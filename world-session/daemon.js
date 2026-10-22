"use strict";
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const mineflayer = require("@wp2508/mineflayer");

const opts = {
  host: process.env.GAME_HOST || "15.204.97.241",
  port: Number(process.env.GAME_PORT || "11648"),
  version: process.env.GAME_VERSION || "26.3",
  auth: process.env.GAME_AUTH || "offline",
  username: process.env.GAME_USERNAME || "GardenKeeper",
  interval: Math.max(30000, Number(process.env.ACTIVITY_INTERVAL_MS || 60000)),
  dataDir: process.env.GAME_DATA_DIR || "/tmp/game-client",
  httpPort: Number(process.env.PORT || "10000")
};
fs.mkdirSync(opts.dataDir, {recursive:true});
let state = {status:"starting",lastChange:new Date().toISOString(),connected:false,attempt:0};
let bot=null, timer=null, reconnect=null, closing=false, starting=false, origin=null, reachedSpawn=false, uptimeAt=0;
let counter=0, consecutiveFailures=0, authBlocked=false, authIssue=null;
function report(status, extra={}){
  state={...state,status,lastChange:new Date().toISOString(),...extra};
  // No credentials or private tokens are logged.
  console.log(JSON.stringify({time:state.lastChange,status,attempt:state.attempt,reason:state.reason||null}));
}
function clearSession(){
  if(timer){clearInterval(timer);timer=null;}
  try{bot?.clearControlStates();}catch{}
}
async function patrol() {
  const b=bot;
  if (!b || !b.entity || !b.entity.position || !state.connected) return;
  // Move conservatively in a small area only when the next blocks are loaded
  // and known safe. Always clear movement, even after a failure.
  const pos=b.entity.position;
  try {
    const distance=origin ? Math.hypot(pos.x-origin.x,pos.z-origin.z) : 0;
    let yaw=pos.yaw || b.entity.yaw || 0;
    if(distance > 3 && origin) yaw=Math.atan2(-(pos.x-origin.x), -(pos.z-origin.z));
    else yaw=b.entity.yaw + (Math.random()-.5)*.6;
    await b.look(yaw, (Math.random()-.5)*.12, true);
    const dx=-Math.sin(yaw), dz=-Math.cos(yaw);
    const here=b.blockAt(pos.offset(0,-1,0));
    const ahead=b.blockAt(pos.offset(dx,0,dz));
    const below=b.blockAt(pos.offset(dx,-1,dz));
    const safeBlock = x=>x&&x.boundingBox==="block"&&!/lava|water|magma|fire|cactus/.test(x.name||"");
    const free = x=>x&&x.boundingBox==="empty"&&!/water|lava|fire/.test(x.name||"");
    if (distance<5 && safeBlock(here) && safeBlock(below) && free(ahead) && Number(b.health||20)>10) {
      b.setControlState("forward",true);
      await new Promise(r=>setTimeout(r,450));
    }
    counter++;
    if(counter%5===0) console.log(JSON.stringify({event:"world_activity",ticks:counter,uptime_seconds:Math.round((Date.now()-uptimeAt)/1000)}));
  }catch(e){console.log(JSON.stringify({event:"activity_error",reason:String(e.message).slice(0,160)}));}
  finally{try{b.setControlState("forward",false)}catch{}}
}
function retry(reason){
  if(closing||reconnect)return;
  if(authBlocked){
    clearSession();
    state.connected=false;
    report("auth_required",{reason:authIssue||"Microsoft account login required",retryAfterSeconds:null});
    return;
  }
  clearSession();
  state.connected=false;
  reachedSpawn=false;
  const wait=Math.min(120000,5000*Math.pow(1.5,Math.min(consecutiveFailures++,8))) + Math.floor(Math.random()*1500);
  report("reconnecting",{reason:String(reason||"disconnected").slice(0,200),retryAfterSeconds:Math.round(wait/1000)});
  reconnect=setTimeout(()=>{reconnect=null; connect();},wait);
}
function connect(){
  if(closing||starting)return;
  starting=true;
  clearSession();
  report("connecting",{attempt:state.attempt+1,connected:false,reason:null});
  try{
    const b=mineflayer.createBot({
      host:opts.host,port:opts.port,version:opts.version,
      auth:opts.auth,username:opts.username,
      profilesFolder:path.join(opts.dataDir,"profiles"),
      checkTimeoutInterval:90000
    });
    bot=b;
    starting=false;
    // Minecraft 26.3 expects client_tick_end after position-bearing packets.
    // Without it, Paper/Vanilla may reject later movement and kick the client.
    const originalWrite = b._client.write.bind(b._client);
    const positionPacketNames = new Set(["position", "position_look", "look", "flying"]);
    b._client.write = function(name, packet) {
      const result = originalWrite(name, packet);
      if (positionPacketNames.has(name)) {
        try { originalWrite("tick_end", {}); } catch (err) {
          if (!b._tickEndWarned) {
            b._tickEndWarned = true;
            console.error("tick_end unavailable:", err.message);
          }
        }
      }
      return result;
    };
    b.once("spawn",()=>{
      if(bot!==b || closing)return;
      authBlocked=false;authIssue=null;
      reachedSpawn=true;state.connected=true;uptimeAt=Date.now();origin=b.entity?.position.clone()||null;
      consecutiveFailures=0;
      report("active",{connected:true,reason:null,attempt:state.attempt});
      timer=setInterval(patrol,opts.interval);
      timer.unref();
    });
    b.on("kicked",r=>{
      const reason=(typeof r==="string" ? r : JSON.stringify(r)).slice(0,240);
      if(/unverified_username|invalid_session|not_authenticated|failed_to_verify/i.test(reason)){
        authBlocked=true;
        authIssue=reason;
        report("auth_required",{connected:false,reason});
      }else report("kicked",{connected:false,reason});
    });
    b.on("error",e=>{report("connection_error",{connected:false,reason:String(e.message).slice(0,240)});});
    b.on("end",r=>{if(bot===b)retry(r);});
  }catch(e){starting=false;retry(e.message);}
}
const server=http.createServer((req,res)=>{
  res.setHeader("Content-Type","application/json");
  res.setHeader("Cache-Control","no-store");
  const st={status:state.status,connected:state.connected,loginSucceeded:reachedSpawn,
    version:opts.version,attempt:state.attempt,reason:state.reason||null,
    uptimeSeconds:state.connected?Math.round((Date.now()-uptimeAt)/1000):null,
    lastChange:state.lastChange};
  if(req.url==="/health"||req.url==="/"){
    res.statusCode=200;res.end(JSON.stringify(st));return;
  }
  res.statusCode=404;res.end('{"error":"not found"}');
});
server.listen(opts.httpPort,"0.0.0.0",()=>{report("ready");connect();});
for(const signal of ["SIGINT","SIGTERM"]) process.on(signal,()=>{
  closing=true;clearSession();if(reconnect)clearTimeout(reconnect);
  try{bot?.quit("Client stopping");}catch{}
  server.close(()=>process.exit(0));
});
