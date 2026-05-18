let viewerHTML = #"""
<!doctype html><html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<title>FoldCast</title>
<style>
  html,body{margin:0;height:100%;background:#000;overflow:hidden;
    touch-action:none;-webkit-user-select:none;user-select:none;
    overscroll-behavior:none;}
  #wrap{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;}
  #screen{max-width:100%;max-height:100%;object-fit:contain;display:block;
    image-rendering:auto;}
  #bar{position:fixed;left:0;right:0;bottom:0;display:flex;gap:6px;
    padding:6px;justify-content:center;background:rgba(0,0,0,.35);
    transition:opacity .3s;font:13px -apple-system,system-ui,sans-serif;}
  #bar.hide{opacity:0;pointer-events:none;}
  #bar button{flex:0 0 auto;padding:8px 10px;border:0;border-radius:8px;
    background:#2c2c2e;color:#fff;font-size:13px;}
  #bar button:active{background:#0a84ff;}
  #hint{position:fixed;top:8px;left:0;right:0;text-align:center;color:#888;
    font:12px -apple-system,system-ui,sans-serif;pointer-events:none;
    transition:opacity .5s;}
</style></head>
<body>
<div id="wrap"><img id="screen" src="/stream" draggable="false"></div>
<div id="hint">tap=click · drag=move window · long-press=right-click · 2-finger=scroll</div>
<div id="bar">
  <button data-rot="0">0°</button>
  <button data-rot="90">90°</button>
  <button data-rot="180">180°</button>
  <button data-rot="270">270°</button>
  <button id="mir">Mirror</button>
  <button id="hideUI">Hide</button>
</div>
<script>
const img = document.getElementById('screen');
const bar = document.getElementById('bar');
let pending = null, sending = false;

function post(k, x, y, dy){
  const b = new URLSearchParams();
  b.set('k',k);
  if(x!=null) b.set('x',x.toFixed(5));
  if(y!=null) b.set('y',y.toFixed(5));
  if(dy!=null) b.set('dy',dy.toFixed(1));
  fetch('/input',{method:'POST',keepalive:true,
    headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:b.toString()}).catch(()=>{});
}
// Coalesce high-frequency move/drag to one per animation frame.
function queue(k,x,y){
  pending={k,x,y};
  if(!sending){ sending=true;
    requestAnimationFrame(()=>{ sending=false;
      if(pending){ post(pending.k,pending.x,pending.y); pending=null; } }); }
}

// Map a client point to normalized coords inside the actual image content
// (object-fit:contain letterboxes it).
function norm(cx,cy){
  const r = img.getBoundingClientRect();
  const nw = img.naturalWidth, nh = img.naturalHeight;
  if(!nw||!nh) return null;
  const scale = Math.min(r.width/nw, r.height/nh);
  const rw = nw*scale, rh = nh*scale;
  const ox = r.left+(r.width-rw)/2, oy = r.top+(r.height-rh)/2;
  let x=(cx-ox)/rw, y=(cy-oy)/rh;
  if(x<0||x>1||y<0||y>1) return null;
  return {x,y};
}

let state=null, lpTimer=null, moved=false, twoFinger=false, lastScrollY=0;

function startGesture(p){
  state='press'; moved=false;
  clearTimeout(lpTimer);
  lpTimer=setTimeout(()=>{ if(state==='press'&&!moved){
      state='rclick'; post('rightclick',p.x,p.y); } }, 550);
  state='press'; window._sp=p;
}
function moveGesture(p){
  if(state==='press'){
    if(Math.hypot(p.x-window._sp.x,p.y-window._sp.y) > 0.006){
      moved=true; clearTimeout(lpTimer);
      state='drag'; post('down',window._sp.x,window._sp.y);
      queue('drag',p.x,p.y);
    }
  } else if(state==='drag'){ queue('drag',p.x,p.y); }
}
function endGesture(p){
  clearTimeout(lpTimer);
  if(state==='drag'){ post('up',p.x,p.y); }
  else if(state==='press'){ post('tap',window._sp.x,window._sp.y); }
  state=null;
}

// Touch
img.addEventListener('touchstart',e=>{
  e.preventDefault();
  if(e.touches.length>=2){ twoFinger=true; state=null; clearTimeout(lpTimer);
    lastScrollY=e.touches[0].clientY; return; }
  twoFinger=false;
  const t=e.touches[0], p=norm(t.clientX,t.clientY); if(p) startGesture(p);
},{passive:false});
img.addEventListener('touchmove',e=>{
  e.preventDefault();
  if(twoFinger && e.touches.length>=2){
    const y=e.touches[0].clientY, dy=y-lastScrollY; lastScrollY=y;
    const c=norm(e.touches[0].clientX,y);
    if(c) post('scroll',c.x,c.y,dy*-1.2);
    return;
  }
  const t=e.touches[0], p=norm(t.clientX,t.clientY); if(p) moveGesture(p);
},{passive:false});
img.addEventListener('touchend',e=>{
  e.preventDefault();
  if(twoFinger){ if(e.touches.length===0) twoFinger=false; return; }
  const t=e.changedTouches[0], p=norm(t.clientX,t.clientY)||window._sp;
  if(p) endGesture(p);
},{passive:false});

// Mouse (desktop browser testing)
let mdown=false;
img.addEventListener('mousedown',e=>{ const p=norm(e.clientX,e.clientY);
  if(p){ mdown=true; startGesture(p);} });
img.addEventListener('mousemove',e=>{ const p=norm(e.clientX,e.clientY);
  if(!p) return; if(mdown) moveGesture(p); else queue('move',p.x,p.y); });
window.addEventListener('mouseup',e=>{ if(!mdown) return; mdown=false;
  const p=norm(e.clientX,e.clientY)||window._sp; if(p) endGesture(p); });
img.addEventListener('wheel',e=>{ e.preventDefault();
  const p=norm(e.clientX,e.clientY); if(p) post('scroll',p.x,p.y,-e.deltaY);
},{passive:false});
img.addEventListener('contextmenu',e=>e.preventDefault());

// Controls
document.querySelectorAll('#bar [data-rot]').forEach(b=>{
  b.onclick=()=>fetch('/ctl?rotate='+b.dataset.rot).catch(()=>{});});
document.getElementById('mir').onclick=()=>{
  window._m=!window._m; fetch('/ctl?mirror='+(window._m?1:0)).catch(()=>{});};
document.getElementById('hideUI').onclick=()=>bar.classList.add('hide');
// Reveal the bar by tapping the very bottom edge.
document.addEventListener('touchstart',e=>{
  if(e.touches[0].clientY > innerHeight-24) bar.classList.remove('hide');},
  {passive:true,capture:true});
setTimeout(()=>{const h=document.getElementById('hint');h.style.opacity=0;},5000);
// Tell the Mac our exact pixel viewport so it resizes the virtual display
// to match — fills the whole panel in any orientation, zero black bars.
function reportSize(){
  const dpr = window.devicePixelRatio || 1;
  const vw = (window.visualViewport ? visualViewport.width : innerWidth);
  const vh = (window.visualViewport ? visualViewport.height : innerHeight);
  const w = Math.round(vw * dpr), h = Math.round(vh * dpr);
  if(w>200 && h>200) fetch('/ctl?fitw='+w+'&fith='+h).catch(()=>{});
}
let _rt; function scheduleReport(){ clearTimeout(_rt);
  _rt=setTimeout(reportSize, 180); }
window.addEventListener('resize', scheduleReport);
if(window.visualViewport){
  visualViewport.addEventListener('resize', scheduleReport); }
// Orientation settles in stages — fire a few times to catch the final size.
window.addEventListener('orientationchange', ()=>{
  [120,400,800].forEach(t=>setTimeout(reportSize,t)); });
window.addEventListener('load', ()=>setTimeout(reportSize, 250));
setTimeout(reportSize, 600);

// Auto-reconnect the stream if it stalls (e.g. during a display resize).
img.addEventListener('error',()=>{ setTimeout(()=>{
  img.src='/stream?t='+Date.now(); }, 800); });
</script>
</body></html>
"""#
