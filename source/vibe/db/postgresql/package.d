module vibe.db.postgresql;

public import dpq2: ValueFormat;
public import dpq2.exception: Dpq2Exception;
public import dpq2.result;
public import dpq2.connection: ConnectionException, connStringCheck, ConnectionStart, CancellationException;
public import dpq2.args;
public import derelict.pq.pq;

static import vibe.core.connectionpool;
import vibe.core.log;
import core.time: Duration, dur;
import core.memory: GC;
import std.exception: enforce;
import std.conv: to;

private alias ConnectionPool = vibe.core.connectionpool.ConnectionPool;
private alias VibeLockedConnection = vibe.core.connectionpool.LockedConnection;

private struct ClientSettings
{
    string connString;
    void delegate(__Conn) afterStartConnectOrReset;
}

class PostgresClient
{
    private ConnectionPool!__Conn pool;
    private immutable ClientSettings settings;

    this(
        string connString,
        uint connNum,
        void delegate(__Conn) afterStartConnectOrReset = null
    )
    {
        enforce(PQisthreadsafe() == 1);
        connString.connStringCheck;

        settings = ClientSettings(
            connString,
            afterStartConnectOrReset
        );

        pool = new ConnectionPool!__Conn({ return new __Conn(settings); }, connNum);
    }

    LockedConnection!__Conn lockConnection()
    {
        logDebugV("get connection from the pool");

        return new LockedConnection!__Conn(pool.lockConnection());
    }
}

// TODO: remove this class
// vibe-core connectionpool already returns raii struct from lockConnection,
// it's destructor returns connection to the pool. This class is only needed for
// backward compatibility.
class LockedConnection(TConnection)
{
    VibeLockedConnection!TConnection m_con;     // struct

    this(VibeLockedConnection!TConnection con)
    {
        m_con = con;
    }

    ~this()
    {
        logDebugV("LockedConnection destructor");
        destroy(m_con);
    }

    alias m_con this;
}

class __Conn : dpq2.Connection
{
    Duration socketTimeout = dur!"seconds"(10);
    Duration statementTimeout = dur!"seconds"(30);

    private const ClientSettings* settings;

    private this(const ref ClientSettings settings)
    {
        this.settings = &settings;

        super(settings.connString); // TODO: switch to non-blocking connection start ctor
        setClientEncoding("UTF8"); // TODO: do only if it is different from UTF8

        import std.conv: to;
        logDebugV("creating new connection, delegate isNull="~(settings.afterStartConnectOrReset is null).to!string);

        if(settings.afterStartConnectOrReset !is null)
            settings.afterStartConnectOrReset(this);
    }

    override void resetStart()
    {
        super.resetStart;

        if(settings.afterStartConnectOrReset !is null)
            settings.afterStartConnectOrReset(this);
    }

    private void waitEndOfRead(in Duration timeout) // TODO: rename to waitEndOf + add FileDescriptorEvent.Trigger argument
    {
        import vibe.core.core;
        import std.typecons: Unique;

        version(Have_vibe_core)
        {
            // vibe-core right now support only read trigger event
            scope event = createFileDescriptorEvent(posixSocketDuplicate, FileDescriptorEvent.Trigger.read);
        }
        else
        {
            import std.socket: Socket;
            Unique!Socket sock = this.socket();
            Unique!FileDescriptorEvent event = createFileDescriptorEvent(sock.handle, FileDescriptorEvent.Trigger.any);
        }

        if(!event.wait(timeout))
            throw new PostgresClientTimeoutException(__FILE__, __LINE__);
    }

    private void doQuery(void delegate() doesQueryAndCollectsResults)
    {
        // Try to get usable connection and send SQL command
        while(true)
        {
            if(status() == CONNECTION_BAD)
                throw new ConnectionException(this, __FILE__, __LINE__);

            if(poll() != PGRES_POLLING_OK)
            {
                waitEndOfRead(socketTimeout);
                continue;
            }
            else
            {
                break;
            }
        }

        logDebugV("doesQuery() call");
        doesQueryAndCollectsResults();
    }

    private immutable(Result) runStatementBlockingManner(void delegate() sendsStatement)
    {
        logDebugV("runStatementBlockingManner");
        immutable(Result)[] res;

        doQuery(()
            {
                sendsStatement();

                try
                {
                    waitEndOfRead(statementTimeout);
                }
                catch(PostgresClientTimeoutException e)
                {
                    logDebugV("Exceeded Posgres query time limit");

                    try
                        cancel(); // cancel sql query
                    catch(CancellationException ce) // means successful cancellation
                        e.msg ~= ", "~ce.msg;

                    throw e;
                }
                finally
                {
                    logDebugV("consumeInput()");
                    consumeInput();

                    while(true)
                    {
                        logDebugV("getResult()");
                        auto r = getResult();
                        if(r is null) break;
                        res ~= r;
                    }
                }
            }
        );

        /*
         I am trying to check connection status with PostgreSQL server
         with PQstatus and it always always return CONNECTION_OK even
         when the cable to the server is unplugged.
                                    – user1972556 (stackoverflow.com)

         ...the idea of testing connections is fairly silly, since the
         connection might die between when you test it and when you run
         your "real" query. Don't test connections, just use them, and
         if they fail be prepared to retry everything since you opened
         the transaction. – Craig Ringer Jan 14 '13 at 2:59
         */
        if(status == CONNECTION_BAD)
            throw new ConnectionException(this, __FILE__, __LINE__);

        enforce(res.length == 1, "Simple query can return only one Result instance, not "~res.length.to!string);

        return res[0];
    }

    immutable(Answer) execStatement(
        string sqlCommand,
        ValueFormat resultFormat = ValueFormat.BINARY
    )
    {
        QueryParams p;
        p.resultFormat = resultFormat;
        p.sqlCommand = sqlCommand;

        return execStatement(p);
    }

    immutable(Answer) execStatement(in ref QueryParams params)
    {
        auto res = runStatementBlockingManner({ sendQueryParams(params); });

        return res.getAnswer;
    }

    void prepareStatement(
        string statementName,
        string sqlStatement,
        Oid[] oids = null
    )
    {
        auto r = runStatementBlockingManner(
                {sendPrepare(statementName, sqlStatement, oids);}
            );

        if(r.status != PGRES_COMMAND_OK)
            throw new PostgresClientException(r.resultErrorMessage, __FILE__, __LINE__);
    }

    immutable(Answer) execPreparedStatement(in ref QueryParams params)
    {
        auto res = runStatementBlockingManner({ sendQueryPrepared(params); });

        return res.getAnswer;
    }

    immutable(Answer) describePreparedStatement(string preparedStatementName)
    {
        auto res = runStatementBlockingManner({ sendDescribePrepared(preparedStatementName); });

        return res.getAnswer;
    }
}

class PostgresClientException : Dpq2Exception // TODO: remove it (use dpq2 exception)
{
    this(string msg, string file, size_t line)
    {
        super(msg, file, line);
    }
}

class PostgresClientTimeoutException : Dpq2Exception
{
    this(string file, size_t line)
    {
        super("Exceeded Posgres query time limit", file, line);
    }
}

unittest
{
    bool raised = false;

    try
    {
        auto client = new PostgresClient("wrong connect string", 2);
    }
    catch(ConnectionException e)
        raised = true;

    assert(raised);
}

version(IntegrationTest) void __integration_test(string connString)
{
    setLogLevel = LogLevel.debugV;

    auto client = new PostgresClient(connString, 3);
    auto conn = client.lockConnection();

    {
        auto res = conn.execStatement(
            "SELECT 123::integer, 567::integer, 'asd fgh'::text",
            ValueFormat.BINARY
        );

        assert(res.getAnswer[0][1].as!PGinteger == 567);
    }

    {
        conn.prepareStatement("stmnt_name", "SELECT 123::integer");

        bool throwFlag = false;

        try
            conn.prepareStatement("wrong_stmnt", "WRONG SQL STATEMENT");
        catch(PostgresClientException e)
            throwFlag = true;

        assert(throwFlag);
    }

    {
        import dpq2.oids: OidType;

        auto a = conn.describePreparedStatement("stmnt_name");

        assert(a.nParams == 0);
        assert(a.OID(0) == OidType.Int4);
    }

    {
        QueryParams p;
        p.preparedStatementName = "stmnt_name";

        auto r = conn.execPreparedStatement(p);

        assert(r.getAnswer[0][0].as!PGinteger == 123);
    }

    {
        // Fibers test
        import vibe.core.concurrency;

        auto future0 = async({
            auto conn = client.lockConnection;
            immutable answer = conn.execStatement("SELECT 'New connection 0'");
            delete conn;
            return 1;
        });

        auto future1 = async({
            auto conn = client.lockConnection;
            immutable answer = conn.execStatement("SELECT 'New connection 1'");
            delete conn;
            return 1;
        });

        immutable answer = conn.execStatement("SELECT 'Old connection'");

        assert(future0 == 1);
        assert(future1 == 1);
        assert(answer.length == 1);
    }

    {
        assert(conn.escapeIdentifier("abc") == "\"abc\"");
    }

    delete conn;
}
