/// The browser page served at `/`: pick a host, watch it live (MJPEG),
/// type and click into it. Asks for the API token once (kept in the
/// browser's localStorage, or pass ?token= in the URL).
enum WebUI {
    static let html = #"""
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SMKVM</title>
<style>
:root{--bg:#f4f4f5;--fg:#18181b;--mut:#71717a;--card:#fff;--line:#e4e4e7;--acc:#2563eb}
@media (prefers-color-scheme:dark){:root{--bg:#18181b;--fg:#f4f4f5;--mut:#a1a1aa;--card:#27272a;--line:#3f3f46;--acc:#60a5fa}}
*{box-sizing:border-box}body{margin:0;font:14px system-ui,sans-serif;background:var(--bg);color:var(--fg)}
header{display:flex;gap:12px;align-items:center;padding:10px 16px;border-bottom:1px solid var(--line);flex-wrap:wrap}
h1{font-size:16px;margin:0}select,input,button{font:inherit;padding:6px 10px;border:1px solid var(--line);border-radius:6px;background:var(--card);color:var(--fg)}
button{cursor:pointer}button.pri{background:var(--acc);color:#fff;border-color:var(--acc)}
main{padding:16px;display:grid;gap:12px}#status{color:var(--mut)}
#screen{max-width:100%;background:#000;border-radius:6px;outline:none;cursor:crosshair;display:block}
#screen:focus{box-shadow:0 0 0 2px var(--acc)}.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.row input[type=text]{flex:1;min-width:200px}small{color:var(--mut)}
</style></head><body>
<header><h1>SMKVM</h1><select id="host"></select><button id="connect">Connect</button><span id="status"></span></header>
<main>
<img id="screen" tabindex="0" alt="console">
<small>Click the picture to focus it: keys you press go to the server; clicks are sent as mouse clicks.</small>
<div class="row"><input type="text" id="text" placeholder="Text to type (Enter sends it with a newline)"><button id="send" class="pri">Type</button></div>
<div class="row" id="keys"></div>
</main>
<script>
const qs=new URLSearchParams(location.search);
let token=qs.get('token')||localStorage.getItem('smkvm-token')||'';
if(!token){token=prompt('SMKVM API token')||'';}
localStorage.setItem('smkvm-token',token);
const H={'Authorization':'Bearer '+token,'Content-Type':'application/json'};
const $=id=>document.getElementById(id);
let cur=null,info=null;
async function api(m,p,b){const r=await fetch(p,{method:m,headers:H,body:b?JSON.stringify(b):undefined});
  if(r.status==401){localStorage.removeItem('smkvm-token');alert('Wrong token');location.reload();}
  return r.json();}
async function hosts(){const list=await api('GET','/api/hosts');const sel=$('host'),keep=sel.value;
  sel.innerHTML=list.map(h=>`<option value="${h.name}">${h.name}${h.open?' ●':''}</option>`).join('');
  if(keep)sel.value=keep;return list;}
function view(){cur=$('host').value;const img=$('screen');
  img.src=`/api/hosts/${encodeURIComponent(cur)}/stream.mjpg?fps=10&token=${encodeURIComponent(token)}`;}
async function poll(){if(!cur)return;info=await api('GET',`/api/hosts/${encodeURIComponent(cur)}`);
  $('status').textContent=info.open?`${info.status||''} ${info.width}×${info.height}`:'not connected';
  $('connect').textContent=info.open?'Disconnect':'Connect';}
$('host').onchange=()=>{view();poll();};
$('connect').onclick=async()=>{await api('POST',`/api/hosts/${encodeURIComponent(cur)}/${info&&info.open?'disconnect':'connect'}`);
  setTimeout(()=>{view();poll();hosts();},800);};
$('send').onclick=async()=>{const t=$('text').value+'\n';$('text').value='';await api('POST',`/api/hosts/${encodeURIComponent(cur)}/type`,{text:t});};
$('text').onkeydown=e=>{if(e.key=='Enter')$('send').click();};
for(const k of ['ctrl+alt+delete','esc','enter','tab','up','down','left','right','f2','f11','f12','del'])
  {const b=document.createElement('button');b.textContent=k;b.onclick=()=>api('POST',`/api/hosts/${encodeURIComponent(cur)}/key`,{keys:k});$('keys').appendChild(b);}
const named={Enter:'enter',Escape:'esc',Backspace:'backspace',Tab:'tab',' ':'space',Delete:'delete',Insert:'insert',
  Home:'home',End:'end',PageUp:'pgup',PageDown:'pgdn',ArrowUp:'up',ArrowDown:'down',ArrowLeft:'left',ArrowRight:'right'};
$('screen').onkeydown=e=>{let k=named[e.key]||(/^F\d+$/.test(e.key)?e.key.toLowerCase():null);
  if(!k&&e.code.startsWith('Key'))k=e.code.slice(3).toLowerCase();
  if(!k&&e.code.startsWith('Digit'))k=e.code.slice(5);
  if(!k&&e.key.length==1)k=e.key;if(!k)return;e.preventDefault();
  const mods=[e.ctrlKey&&'ctrl',e.altKey&&'alt',e.metaKey&&'win'].filter(Boolean);
  if(mods.length==0&&e.key.length==1){api('POST',`/api/hosts/${encodeURIComponent(cur)}/type`,{text:e.key});return;}
  if(e.shiftKey)mods.push('shift');api('POST',`/api/hosts/${encodeURIComponent(cur)}/key`,{keys:[...mods,k].join('+')});};
$('screen').onclick=e=>{if(!info||!info.width)return;const r=e.target.getBoundingClientRect();
  const x=Math.round((e.clientX-r.left)/r.width*info.width),y=Math.round((e.clientY-r.top)/r.height*info.height);
  e.target.focus();api('POST',`/api/hosts/${encodeURIComponent(cur)}/mouse`,{x,y,action:'click'});};
hosts().then(l=>{const open=l.find(h=>h.open);if(open)$('host').value=open.name;view();poll();});
setInterval(poll,2000);
</script></body></html>
"""#
}
