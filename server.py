#!/usr/bin/env python3
import base64,json,os,re,secrets,sqlite3,threading,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlsplit
OP=os.getenv("OPERATOR_TOKEN","");AG=os.getenv("AGENT_TOKEN","")
if min(len(OP),len(AG))<24 or OP==AG: raise SystemExit("Set distinct 24+ character tokens")
DB=os.getenv("DB_PATH","/tmp/mcbridge.sqlite3")
db=sqlite3.connect(DB,check_same_thread=False)
db.execute("CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, command TEXT, status TEXT, created REAL, started REAL, finished REAL, timeout INTEGER, stdout TEXT, stderr TEXT, code INTEGER)")
db.commit();lock=threading.RLock();last_seen=[None]
def js(x):return json.dumps(x,ensure_ascii=False,separators=(",",":")).encode()
def create(command,timeout):
    if not isinstance(command,str) or not command.strip() or len(command)>4000:raise ValueError("Invalid command")
    timeout=int(timeout)
    if not 1<=timeout<=120:raise ValueError("Invalid timeout")
    with lock:
        if db.execute("SELECT COUNT(*) FROM jobs WHERE status IN ('queued','running')").fetchone()[0]>=30:raise ValueError("Queue full")
        jid=secrets.token_hex(12)
        db.execute("INSERT INTO jobs(id,command,status,created,timeout) VALUES(?,?,'queued',?,?)",(jid,command,time.time(),timeout));db.commit()
    return jid
def get(jid):
    if not isinstance(jid,str) or not re.fullmatch("[0-9a-f]{24}",jid):return None
    with lock:r=db.execute("SELECT id,status,created,started,finished,timeout,stdout,stderr,code FROM jobs WHERE id=?",(jid,)).fetchone()
    if not r:return None
    x=dict(zip(("id","status","created_at","started_at","finished_at","timeout_secs","stdout","stderr","exit_code"),r))
    for k in ("stdout","stderr"):x[k]=base64.b64decode(x[k]).decode("utf8","replace") if x[k] else ""
    return x
def status():
    with lock: rows=db.execute("SELECT status,count(*) FROM jobs GROUP BY status").fetchall()
    return {"relay":"online","agent_last_seen_ago_sec":round(time.time()-last_seen[0],1) if last_seen[0] else None,"jobs":dict(rows)}
def claim():
    with lock:
        db.execute("UPDATE jobs SET status='unknown',finished=? WHERE status='running' AND started<?",(time.time(),time.time()-300))
        r=db.execute("SELECT id,command,timeout FROM jobs WHERE status='queued' ORDER BY created LIMIT 1").fetchone()
        if r:db.execute("UPDATE jobs SET status='running',started=? WHERE id=?",(time.time(),r[0]))
        db.commit()
    return r
def finish(x):
    try:
        jid=x["id"];code=int(x["exit_code"]);out=x["stdout_b64"];err=x["stderr_b64"]
        if not isinstance(jid,str) or not re.fullmatch("[0-9a-f]{24}",jid):return False
        if not isinstance(out,str) or not isinstance(err,str) or max(len(out),len(err))>180000:return False
        base64.b64decode(out,validate=True);base64.b64decode(err,validate=True)
    except (KeyError,ValueError,TypeError):return False
    with lock:
        r=db.execute("SELECT status FROM jobs WHERE id=?",(jid,)).fetchone()
        if not r or r[0] not in ("running","done"):return False
        if r[0]=="running":
            db.execute("UPDATE jobs SET status='done',finished=?,stdout=?,stderr=?,code=? WHERE id=?",(time.time(),out,err,code,jid));db.commit()
    return True
def run(name,args):
    if name=="remote_status":return status()
    if name=="remote_result":return get(args.get("job_id")) or {"error":"not found"}
    if name!="remote_exec":raise ValueError("Unknown tool")
    jid=create(args.get("command",""),args.get("timeout_secs",40))
    deadline=time.monotonic()+min(max(int(args.get("wait_secs",20)),0),25)
    while time.monotonic()<deadline:
        x=get(jid)
        if x and x["status"]!="queued" and x["status"]!="running":return x
        time.sleep(.4)
    return get(jid)
TOOLS=[
 {"name":"remote_exec","description":"Execute a POSIX shell command as game-container user and return result or job id","inputSchema":{"type":"object","properties":{"command":{"type":"string"},"timeout_secs":{"type":"integer"},"wait_secs":{"type":"integer"}},"required":["command"]}},
 {"name":"remote_result","description":"Read command result by job id","inputSchema":{"type":"object","properties":{"job_id":{"type":"string"}},"required":["job_id"]}},
 {"name":"remote_status","description":"Check relay and agent heartbeat","inputSchema":{"type":"object","properties":{}}}]
class H(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def auth(self,kind):
        expected=AG if kind=="agent" else OP
        header=self.headers.get("X-Agent-Token" if kind=="agent" else "X-Operator-Token","")
        if kind=="operator" and not header:
            h=self.headers.get("Authorization","")
            if h.startswith("Bearer "):header=h[7:]
        return secrets.compare_digest(expected,header)
    def send(self,code,obj,raw=False,headers=None):
        data=obj if raw else js(obj)
        self.send_response(code)
        self.send_header("Content-Type","text/plain; charset=utf-8" if raw else "application/json")
        self.send_header("Cache-Control","no-store")
        self.send_header("Content-Length",str(len(data)))
        for k,v in (headers or {}).items():self.send_header(k,v)
        self.end_headers()
        if data:self.wfile.write(data)
    def body(self):
        n=int(self.headers.get("Content-Length","0"))
        if n<1 or n>220000:raise ValueError("Invalid body size")
        x=json.loads(self.rfile.read(n))
        if not isinstance(x,dict):raise ValueError("Expected JSON object")
        return x
    def do_GET(self):
        path=urlsplit(self.path).path
        if path=="/health":return self.send(200,{"status":"ok"})
        kind="agent" if path=="/v1/agent/next" else "operator"
        if not self.auth(kind):return self.send(401,{"error":"unauthorized"})
        if path=="/v1/agent/next":
            last_seen[0]=time.time();r=claim()
            if not r:return self.send(204,b"",True)
            return self.send(200,(r[0]+"|"+base64.b64encode(r[1].encode()).decode()+"|"+str(r[2])+"\n").encode(),True)
        if path=="/v1/status":return self.send(200,status())
        if path.startswith("/v1/jobs/"):
            x=get(path.rsplit("/",1)[-1])
            return self.send(200,x) if x else self.send(404,{"error":"not found"})
        return self.send(404,{"error":"not found"})
    def do_POST(self):
        path=urlsplit(self.path).path
        kind="agent" if path=="/v1/agent/result" else "operator"
        if not self.auth(kind):return self.send(401,{"error":"unauthorized"})
        try:
            x=self.body()
            if path=="/v1/agent/result":
                last_seen[0]=time.time();ok=finish(x);return self.send(200 if ok else 400,{"ok":ok})
            if path=="/v1/jobs":return self.send(201,{"id":create(x.get("command",""),x.get("timeout_secs",40)),"status":"queued"})
            if path=="/mcp":
                method=x.get("method");mid=x.get("id")
                if method=="notifications/initialized":return self.send(202,b"",True)
                if method=="initialize":result={"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"mcbridge","version":"0.2"}}
                elif method=="tools/list":result={"tools":TOOLS}
                elif method=="tools/call":
                    p=x.get("params") or {}
                    try: result={"content":[{"type":"text","text":json.dumps(run(p.get("name"),p.get("arguments") or {}))}]}
                    except Exception as e:result={"isError":True,"content":[{"type":"text","text":str(e)}]}
                elif method=="ping":result={}
                else:return self.send(200,{"jsonrpc":"2.0","id":mid,"error":{"code":-32601,"message":"Unknown method"}})
                return self.send(200,{"jsonrpc":"2.0","id":mid,"result":result},headers={"MCP-Protocol-Version":"2025-03-26"})
            return self.send(404,{"error":"not found"})
        except (ValueError,TypeError,KeyError) as e:return self.send(400,{"error":str(e)})
        except Exception:return self.send(500,{"error":"internal error"})
if __name__=="__main__":
    ThreadingHTTPServer(("0.0.0.0",int(os.getenv("PORT","8080"))),H).serve_forever()
