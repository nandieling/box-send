import Foundation

enum UI {
    static var index: HTTPServer.Response {
        .init(200, "text/html; charset=utf-8", Data(page.utf8))
    }

    static let page = """
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>box-send 控制台</title>
<style>
:root{--bg:#f4f5f6;--card:#fff;--line:#e2e5e8;--txt:#1d2024;--mut:#68707b;--acc:#0b57d0;--ok:#0a7d40;--err:#c22525}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--txt);font:14px/1.55 -apple-system,"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif}
header{background:#14171c;color:#fff;padding:10px 20px;display:flex;gap:14px;align-items:baseline}
header b{font-size:15px;letter-spacing:.02em}
header .st{color:#8f99a6;font-size:12px}
main{max-width:1000px;margin:16px auto 60px;padding:0 16px;display:grid;gap:14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:14px 16px}
.card h2{margin:0 0 10px;font-size:12px;letter-spacing:.08em;color:var(--mut);text-transform:uppercase}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:9px 14px}
@media(max-width:700px){.grid2{grid-template-columns:1fr}}
label{display:flex;flex-direction:column;gap:3px;font-size:12px;color:var(--mut)}
input,select,textarea{font:13px/1.4 inherit;padding:6px 8px;border:1px solid var(--line);border-radius:6px;background:#fff;color:var(--txt);width:100%}
textarea.mono{font:12px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace}
button{font:13px inherit;padding:7px 14px;border-radius:6px;border:1px solid var(--line);background:#fff;cursor:pointer}
button:hover{border-color:#b9c0c8}
button.primary{background:var(--acc);border-color:var(--acc);color:#fff}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.msg{font-size:12px;min-height:16px}
.msg.ok{color:var(--ok)}.msg.err{color:var(--err)}
table{width:100%;border-collapse:collapse;font-size:13px}
td,th{border-bottom:1px solid var(--line);padding:5px 6px;text-align:left}
td input{width:130px}
pre{background:#10141a;color:#d7dee7;padding:10px;border-radius:6px;font:12px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;overflow:auto;max-height:280px;white-space:pre-wrap;word-break:break-all}
.chips{display:flex;gap:8px;flex-wrap:wrap}
.chip{background:#eef1f4;border:1px solid var(--line);border-radius:6px;padding:4px 10px;font-size:12px;color:#3a414b}
.chip b{color:var(--txt)}
.tag{display:inline-flex;align-items:center;gap:5px;border:1px solid var(--line);border-radius:6px;padding:3px 9px;font-size:12px;background:#fff;cursor:pointer}
.tag input{width:auto}
.mut{color:#8a919b;font-size:12px}
</style>
</head>
<body>
<header><b>box-send</b><span class="st">PT 批量转种 + 下载器推送 · 配置控制台</span></header>
<main>

<section class="card">
  <h2>运行状态</h2>
  <div class="chips" id="chips"><span class="chip">加载中…</span></div>
  <div class="row" style="margin-top:12px">
    <button onclick="refreshStatus()">刷新状态</button>
    <button class="primary" onclick="syncGist()">立即同步 Gist cookie</button>
    <span class="msg" id="st-msg"></span>
  </div>
  <div style="margin-top:10px"><h2 style="margin-bottom:6px">最近日志</h2><pre id="notes" style="max-height:200px">-</pre></div>
</section>

<section class="card">
  <h2>Gist Cookie 同步（PT-depiler 备份源）</h2>
  <div class="grid2">
    <label>gistID<input id="g_id" placeholder="gist 地址中最后一段"></label>
    <label>Access Token<input id="g_token" type="password" placeholder="github_pat_..."></label>
    <label>备份密码（PT-depiler 加密密钥，可空）<input id="g_key"></label>
    <label>轮询间隔（分钟，≥5）<input id="g_poll" type="number" min="5" step="5"></label>
  </div>
</section>

<section class="card">
  <h2>下载器</h2>
  <div class="grid2">
    <label>类型<select id="d_type"><option value="qbittorrent">qBittorrent</option><option value="transmission">Transmission</option></select></label>
    <label>地址<input id="d_url" placeholder="http://127.0.0.1:8080"></label>
    <label>用户名<input id="d_user"></label>
    <label>密码<input id="d_pass" type="password"></label>
    <label>保存路径 savePath（空 = 默认）<input id="d_save"></label>
    <label>分类 category（空 = 默认）<input id="d_cat"></label>
    <label>默认上传限速 MB/s（0 = 不限速）<input id="d_up" type="number" step="0.1" min="0"></label>
    <label>推送策略<select id="d_policy"><option value="always">always：转种失败也推</option><option value="onSuccess">onSuccess：全部成功才推</option></select></label>
    <label class="chk"><input type="checkbox" id="d_skip" style="width:auto"> 跳过种子校验 skipChecking</label>
  </div>
</section>

<section class="card">
  <h2>站点上传限速（按源站点；0 = 跟随全局默认）</h2>
  <table><thead><tr><th>站点</th><th>upLimit (MB/s)</th><th></th></tr></thead><tbody id="limits-tb"></tbody></table>
  <div class="mut" style="margin-top:6px">例：CMCT 128、Audiences 125 —— 上传过快会被站点风控</div>
</section>

<section class="card">
  <h2>转种目标站（按当前顺序执行）</h2>
  <div class="row" id="targets"></div>
</section>

<section class="card">
  <h2>手动任务</h2>
  <div class="grid2">
    <label>源站详情页 URL<input id="r_detail" placeholder="https://hdhome.org/details.php?id=12345"></label>
    <label>源站（留空 = 按 URL 自动识别）<select id="r_site"><option value="">自动</option></select></label>
  </div>
  <div class="row" style="margin-top:10px">
    <button class="primary" onclick="runTask(false)">转种 + 推下载器</button>
    <button onclick="runTask(true)">仅推下载器</button>
    <span class="msg" id="run-msg"></span>
  </div>
  <pre id="run-out" style="display:none;margin-top:10px"></pre>
</section>

<section class="card">
  <h2>完整配置 boxsend.json</h2>
  <div class="row">
    <button class="primary" onclick="saveAll()">保存全部（表单 + JSON）</button>
    <button onclick="formatJson()">格式化 JSON</button>
    <button onclick="loadConfig()">重新载入</button>
    <span class="msg" id="save-msg"></span>
  </div>
  <textarea id="json" class="mono" rows="16" style="margin-top:10px"></textarea>
  <div class="mut" style="margin-top:6px">保存会先做 JSON 校验和结构校验，失败不写盘。sourceSites / userAgent 等高级字段请直接编辑 JSON。</div>
</section>

</main>
<script>
let cfg = null;
let token = localStorage.getItem('bs_token') || '';

function $(id){ return document.getElementById(id); }
function setMsg(id, cls, text){ const el=$(id); el.className='msg '+(cls||''); el.textContent=text||''; }
function mb2b(v){ const n=parseFloat(v); return (isNaN(n)||n<=0)?0:Math.round(n*1048576); }
function b2mb(v){ return v>0?+(v/1048576).toFixed(2):0; }

async function api(path, body){
  const opt={ method: body===undefined?'GET':'POST', headers:{'X-BoxSend-Token':token} };
  if(body!==undefined){ opt.headers['Content-Type']='application/json'; opt.body=JSON.stringify(body); }
  const r=await fetch(path, opt);
  if(r.status===401){
    const t=prompt('访问令牌（box-send serve --token 的值）:');
    if(t){ token=t; localStorage.setItem('bs_token',t); return api(path, body); }
    throw new Error('unauthorized');
  }
  return r.json();
}

async function loadConfig(){
  try{
    const r=await api('/api/config');
    if(!r.ok){ setMsg('save-msg','err', r.error||'加载失败'); return; }
    if(!r.raw || !r.raw.trim()){ setMsg('save-msg','err','服务器返回的配置为空'); return; }
    cfg=JSON.parse(r.raw);
    $('json').value=r.raw;
    fillFromCfg();
  }catch(e){
    setMsg('save-msg','err','加载失败: '+e.message+'（点「重新载入」重试）');
  }
}
function fillFromCfg(){
  if(!cfg) return;
  const g=cfg.gistSync||{}, d=cfg.downloader||{};
  $('g_id').value=g.gistID||''; $('g_token').value=g.token||'';
  $('g_key').value=g.encryptionKey||''; $('g_poll').value=g.pollMinutes||30;
  $('d_type').value=d.type||'qbittorrent'; $('d_url').value=d.url||'';
  $('d_user').value=d.username||''; $('d_pass').value=d.password||'';
  $('d_save').value=d.savePath||''; $('d_cat').value=d.category||'';
  $('d_up').value=b2mb(d.defaultUpLimit||0); $('d_policy').value=d.pushPolicy||'always';
  $('d_skip').checked=!!d.skipChecking;
  const tb=$('limits-tb'); tb.innerHTML='';
  const su=d.siteUpLimits||{};
  for(const s of (cfg.sourceSites||[])){
    const tr=document.createElement('tr');
    tr.innerHTML='<td>'+s.id+' <span class="mut">'+s.url+'</span></td>'+
      '<td><input data-id="'+s.id+'" value="'+b2mb(su[s.id]||0)+'" type="number" step="0.1" min="0"></td><td></td>';
    tb.appendChild(tr);
  }
  const tt=$('targets'); tt.innerHTML='';
  const tset=new Set(cfg.targetSites||[]);
  for(const s of (cfg.sourceSites||[])){
    const l=document.createElement('label'); l.className='tag';
    const cb=document.createElement('input'); cb.type='checkbox'; cb.dataset.id=s.id; cb.checked=tset.has(s.id);
    l.appendChild(cb); l.appendChild(document.createTextNode(' '+s.id));
    tt.appendChild(l);
  }
  const rs=$('r_site'); rs.innerHTML='<option value="">自动</option>';
  for(const s of (cfg.sourceSites||[])) rs.insertAdjacentHTML('beforeend','<option value="'+s.id+'">'+s.id+'</option>');
}
function collectFromForm(){
  if(!cfg) return;
  cfg.gistSync={ gistID:$('g_id').value.trim(), token:$('g_token').value.trim(),
    encryptionKey:$('g_key').value.trim(), pollMinutes:Math.max(5,parseInt($('g_poll').value||'30',10)) };
  cfg.downloader=Object.assign({}, cfg.downloader, {
    type:$('d_type').value, url:$('d_url').value.trim(), username:$('d_user').value.trim(),
    password:$('d_pass').value, savePath:$('d_save').value.trim(), category:$('d_cat').value.trim(),
    defaultUpLimit:mb2b($('d_up').value), pushPolicy:$('d_policy').value, skipChecking:$('d_skip').checked });
  const su={};
  document.querySelectorAll('#limits-tb input').forEach(i=>{ const v=mb2b(i.value); if(v>0) su[i.dataset.id]=v; });
  cfg.downloader.siteUpLimits=su;
  cfg.targetSites=[...document.querySelectorAll('#targets input')].filter(c=>c.checked).map(c=>c.dataset.id);
  $('json').value=JSON.stringify(cfg, null, 2);
}
async function saveAll(){
  try{ collectFromForm(); }catch(e){ setMsg('save-msg','err','表单收集出错: '+e.message); return; }
  const t=$('json').value;
  if(!t || !t.trim()){ setMsg('save-msg','err','配置为空：先点「重新载入」再保存'); return; }
  try{ JSON.parse(t); }catch(e){
    setMsg('save-msg','err','JSON 格式错误: '+e.message+'（未手改过的话点「重新载入」再试）');
    return;
  }
  try{
    const r=await api('/api/config', {raw:t});
    setMsg('save-msg', r.ok?'ok':'err', r.ok?'已保存到 Config/boxsend.json':'保存失败: '+(r.error||''));
    if(r.ok) loadConfig();
  }catch(e){ setMsg('save-msg','err','请求失败: '+e.message); }
}
function formatJson(){
  try{ const t=$('json'); t.value=JSON.stringify(JSON.parse(t.value), null, 2); setMsg('save-msg','ok','已格式化'); }
  catch(e){ setMsg('save-msg','err', e.message); }
}
async function refreshStatus(){
  try{
    const s=await api('/api/status');
    if(!s.ok) return;
    const chips=$('chips');
    const hosts=Object.keys(s.cookieHosts||{});
    const last=s.lastGistSync? new Date(s.lastGistSync*1000).toLocaleString():'从未';
    chips.innerHTML=
      '<span class="chip">cookie 站点 <b>'+hosts.length+'</b></span>'+
      '<span class="chip">'+hosts.map(h=>h+':'+(s.cookieHosts[h]||0)).join(' ')+'</span>'+
      '<span class="chip">上次 gist 同步 <b>'+last+'</b></span>'+
      '<span class="chip">下载器 <b>'+s.downloader+'</b></span>';
    $('notes').textContent=(s.notes&&s.notes.length)?s.notes.join('\\n'):'（暂无）';
  }catch(e){}
}
async function syncGist(){
  setMsg('st-msg','','同步中…（走 api.github.com，网络不佳可能要等 1 分钟）');
  try{
    const r=await api('/api/gist-sync', {});
    setMsg('st-msg', r.ok?'ok':'err', r.message||r.error||'');
  }catch(e){ setMsg('st-msg','err','请求失败: '+e.message); }
  refreshStatus();
}
async function runTask(skipReseed){
  const detail=$('r_detail').value.trim();
  if(!detail){ setMsg('run-msg','err','请填写详情页 URL'); return; }
  setMsg('run-msg','','执行中（批量转种可能需要 1-2 分钟）…');
  try{
    const r=await api('/api/run', {detail, site:$('r_site').value||undefined, skipReseed});
    const pre=$('run-out'); pre.style.display='block';
    pre.textContent=r.report||JSON.stringify(r, null, 2);
    setMsg('run-msg', r.ok?'ok':'err', r.ok?'完成':'失败: '+(r.error||''));
  }catch(e){ setMsg('run-msg','err','请求失败: '+e.message); }
  refreshStatus();
}
loadConfig().then(refreshStatus).catch(e=>{ const m=$('save-msg'); m.className='msg err'; m.textContent='加载失败: '+e.message; });
setInterval(refreshStatus, 30000);
</script>
</body>
</html>
"""
}
