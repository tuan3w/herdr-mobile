#!/usr/bin/env python3
"""Builds a standalone web gallery from a prototype's PNGs and a small spec.

    python3 make_gallery.py spec.json OUT_DIR PNG_DIR

OUT_DIR gets index.html and img/ (copies of the PNGs the spec names). Open
OUT_DIR/index.html in a browser; no server needed.

The spec (see SKILL.md of herdr-prototype for what each field is for):

{
  "title": "Idle agents all look the same",
  "problem": "the owner's complaint, in their words",
  "moment": "who holds the phone, where, why",
  "causes": ["cause, with file:line", ...],            # from tracing the code
  "baseline": "0-today",                               # id of the baseline
  "pick": "D-both",                                    # builder's pick (optional)
  "compare_default": ["0-today", "D-both"],            # shown in Compare at first (optional)
  "compare_start": 0.4,                                # 0..1: where the pages open; point at the part that differs
  "critic_rank": ["D-both", "A-ask", ...],             # optional
  "variants": [{
      "id": "A-ask",                  # PNG names: <id>-light.png, <id>-dark.png
      "name": "Name it by what you asked",
      "axis": "identity",             # or "baseline"
      "idea": "one sentence",
      "wins": "when it wins",
      "costs": "what it costs",
      "sketch": [                     # a few mock rows that show the idea
        {"k": "row", "st": "idle", "t": "Fix the locale bug",
         "s": "claude · studio-mac", "time": "idle 12m"},
        {"k": "group", "t": "payments-api", "s": "studio-mac · 3"},
        {"k": "fold", "t": "7 idle for 2h or more", "s": "oldest 3d"}
      ]
  }],
  "findings": [{"sev": "Friction", "variant": "B-fold", "text": "..."}],
  "invented": ["fields the real app may not be able to supply"],
  "standins": ["parts drawn with stand-ins, not real widgets"],
  "unchecked": ["what pixels cannot tell you here"],
  "decisions": [{"q": "question for the owner", "rec": "your recommendation"}],
  "rerender": "command that regenerates the PNGs"
}
"""
import json
import shutil
import sys
from pathlib import Path

PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__</title>
<style>
:root{--bg:#fafaf8;--fg:#1d1d1b;--mut:#6b6b66;--line:#e4e3de;--card:#fff;--acc:#4c5bd4;--warn:#c4571a;--ok:#237a4b}
*{box-sizing:border-box}
body{margin:0;font:15px/1.5 -apple-system,Inter,system-ui,sans-serif;background:var(--bg);color:var(--fg)}
header{padding:28px 32px 8px;max-width:1200px;margin:auto}
h1{margin:0 0 6px;font-size:26px;letter-spacing:-.4px}
.sub{color:var(--mut);max-width:820px}
.quote{border-left:3px solid var(--acc);padding:2px 12px;margin:14px 0;color:var(--fg)}
nav{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);z-index:5;padding:0 32px}
nav .in{max-width:1200px;margin:auto;display:flex;gap:4px;align-items:center}
nav button{border:0;background:none;padding:12px 14px;font:inherit;color:var(--mut);cursor:pointer;border-bottom:2px solid transparent}
nav button.on{color:var(--fg);border-color:var(--fg);font-weight:600}
nav .sp{flex:1}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:8px;overflow:hidden}
.seg button{padding:5px 12px;border:0;border-bottom:0;font-size:13px}
.seg button.on{background:var(--fg);color:#fff}
main{max-width:1200px;margin:auto;padding:22px 32px 80px}
section{display:none}section.on{display:block}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px}
.card h3{margin:0 0 2px;font-size:17px}
.tag{display:inline-block;font-size:12px;padding:1px 8px;border-radius:99px;background:#eceae4;color:var(--mut);margin-right:4px}
.tag.pick{background:#e3f1e8;color:var(--ok)}.tag.crit{background:#e6e8fb;color:var(--acc)}.tag.base{background:#f4e6dc;color:var(--warn)}
.kv{margin:8px 0 0;font-size:14px}.kv b{display:inline-block;min-width:44px;color:var(--mut);font-weight:600}
.sketch{margin:12px 0;border:1px solid var(--line);border-radius:10px;background:#fcfcfa;overflow:hidden}
.srow{display:flex;gap:10px;padding:8px 10px;border-bottom:1px solid var(--line);align-items:flex-start}
.srow:last-child{border-bottom:0}
.g{flex:none;width:14px;height:14px;border-radius:50%;margin-top:3px;border:2px solid #8a8a85}
.g.working{border-color:#b8860b;border-right-color:transparent}.g.done{background:var(--ok);border-color:var(--ok)}
.g.blocked{background:var(--warn);border-color:var(--warn)}
.srow .t{font-weight:500;line-height:1.25}.srow .s{font-size:12.5px;color:var(--mut)}
.srow .tm{margin-left:auto;font-size:12px;color:var(--mut);white-space:nowrap}
.sgroup{padding:8px 10px 2px;font-size:13px;font-weight:600}.sgroup span{color:var(--mut);font-weight:400}
.sfold{padding:8px 10px;color:var(--mut);font-size:13px}.sfold b{display:block;color:var(--fg);font-weight:500;font-size:14px}
.thumb{width:100%;border-radius:8px;border:1px solid var(--line);display:block;cursor:zoom-in;max-height:360px;object-fit:cover;object-position:top}
.cols{display:flex;gap:14px;overflow-x:auto;padding-bottom:8px}
.col{flex:none;width:300px}
.col h4{margin:0 0 6px;font-size:14px}
.scroller{height:78vh;overflow-y:auto;border:1px solid var(--line);border-radius:10px;background:#fff}
.scroller img{width:100%;display:block;cursor:zoom-in}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:12px}
.chips label{border:1px solid var(--line);border-radius:99px;padding:3px 10px;font-size:13px;cursor:pointer;background:var(--card)}
.chips input{margin-right:5px}
table{border-collapse:collapse;width:100%;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{padding:9px 12px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top;font-size:14px}
th{background:#f3f2ee;font-weight:600}
.sev{font-weight:600}.sev.Broken{color:#b3261e}.sev.Friction{color:var(--warn)}.sev.Noise,.sev.Inconsistent{color:#7a5d00}.sev.Polish{color:var(--mut)}
ul.plain{margin:6px 0 16px;padding-left:20px}
.note{background:#fff7e6;border:1px solid #f0dca8;border-radius:10px;padding:10px 14px;margin:12px 0;font-size:14px}
.dec{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin-bottom:10px}
.dec .rec{color:var(--ok);font-size:14px;margin-top:4px}
#lb{position:fixed;inset:0;background:rgba(0,0,0,.82);display:none;z-index:20;overflow:auto;padding:20px;cursor:zoom-out}
#lb img{display:block;margin:auto;max-width:min(720px,100%)}
code{background:#eceae4;padding:1px 5px;border-radius:4px;font-size:13px}
</style></head><body>
<header><h1 id="title"></h1><div id="moment" class="sub"></div><div id="problem" class="quote"></div></header>
<nav><div class="in">
 <button data-tab="ideas" class="on">Ideas</button><button data-tab="compare">Compare</button>
 <button data-tab="critic">Critic</button><button data-tab="decide">Decide</button>
 <span class="sp"></span><span class="seg" id="theme"><button data-th="light" class="on">Light</button><button data-th="dark">Dark</button></span>
</div></nav>
<main>
<section id="ideas" class="on"></section><section id="compare"></section>
<section id="critic"></section><section id="decide"></section>
</main>
<div id="lb"><img alt=""></div>
<script>
const D = __DATA__;
let theme='light';
const $=(s,r=document)=>r.querySelector(s), $$=(s,r=document)=>[...r.querySelectorAll(s)];
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const img=(id)=>`img/${id}-${theme}.png`;
const by=Object.fromEntries(D.variants.map(v=>[v.id,v]));
function tags(v){let t=`<span class="tag">${esc(v.axis)}</span>`;
 if(v.id===D.baseline)t=`<span class="tag base">today</span>`;
 if(v.id===D.pick)t+=`<span class="tag pick">builder's pick</span>`;
 const r=(D.critic_rank||[]).indexOf(v.id);if(r>=0)t+=`<span class="tag crit">critic #${r+1}</span>`;return t}
function sketch(rows){if(!rows||!rows.length)return'';return `<div class="sketch">`+rows.map(r=>{
 if(r.k==='group')return `<div class="sgroup">${esc(r.t)} <span>${esc(r.s)}</span></div>`;
 if(r.k==='fold')return `<div class="sfold"><b>${esc(r.t)}</b>${esc(r.s)}</div>`;
 return `<div class="srow"><i class="g ${esc(r.st)}"></i><div><div class="t">${esc(r.t)}</div><div class="s">${esc(r.s)}</div></div><div class="tm">${esc(r.time)}</div></div>`}).join('')+`</div>`}
function list(a){return a&&a.length?`<ul class="plain">${a.map(x=>`<li>${esc(x)}</li>`).join('')}</ul>`:''}
function render(){
 $('#title').textContent=D.title;$('#moment').textContent=D.moment||'';$('#problem').textContent='“'+D.problem+'”';
 let h='';
 if(D.causes&&D.causes.length)h+=`<h3>Why it looks like this today</h3>${list(D.causes)}`;
 h+=`<div class="grid">`+D.variants.map(v=>`<div class="card"><h3>${esc(v.name)}</h3><div>${tags(v)}</div>
  <p style="margin:8px 0 0">${esc(v.idea)}</p>${sketch(v.sketch)}
  <img class="thumb" style="object-position:0 ${(D.compare_start||0)*100}%" src="${img(v.id)}" data-zoom="${v.id}" loading="lazy" alt="${esc(v.name)}">
  ${v.wins?`<div class="kv"><b>Wins</b> ${esc(v.wins)}</div>`:''}${v.costs?`<div class="kv"><b>Costs</b> ${esc(v.costs)}</div>`:''}</div>`).join('')+`</div>`;
 if((D.invented||[]).length||(D.standins||[]).length||(D.unchecked||[]).length)
  h+=`<div class="note">${D.invented?.length?`<b>Invented data</b>${list(D.invented)}`:''}${D.standins?.length?`<b>Stand-ins, not the real widget</b>${list(D.standins)}`:''}${D.unchecked?.length?`<b>Not checked</b>${list(D.unchecked)}`:''}</div>`;
 if(D.rerender)h+=`<p class="sub">Re-render: <code>${esc(D.rerender)}</code></p>`;
 $('#ideas').innerHTML=h;
 // compare
 const on=new Set($$('#chips input:checked').map(i=>i.value));
 const dflt=new Set(D.compare_default||D.variants.map(v=>v.id));var first=!$('#chips');
 let c=`<div class="chips" id="chips">`+D.variants.map(v=>`<label><input type="checkbox" value="${v.id}" ${(first?dflt.has(v.id):on.has(v.id))?'checked':''}>${esc(v.name)}</label>`).join('')+`</div><div class="cols" id="cols"></div>
  <p class="sub">The columns scroll together. Click a screen to enlarge it.</p>`;
 $('#compare').innerHTML=c;drawCols();
 $('#chips').addEventListener('change',drawCols);
 // critic
 $('#critic').innerHTML=(D.findings&&D.findings.length)?`<p class="sub">From a reviewer who saw only the pictures and the moment${D.critic_rank?', and ranked: '+D.critic_rank.map(i=>esc(by[i]?.name||i)).join(' › '):''}.</p>
  <table><tr><th>Severity</th><th>Where</th><th>What the person experiences</th></tr>${D.findings.map(f=>`<tr><td class="sev ${esc(f.sev)}">${esc(f.sev)}</td><td>${esc(by[f.variant]?.name||f.variant||'')}</td><td>${esc(f.text)}</td></tr>`).join('')}</table>`:'<p class="sub">No critique recorded.</p>';
 $('#decide').innerHTML=(D.decisions||[]).map(d=>`<div class="dec"><b>${esc(d.q)}</b>${d.rec?`<div class="rec">Recommendation: ${esc(d.rec)}</div>`:''}</div>`).join('')||'<p class="sub">No open decisions.</p>';
}
// Pages open at the part that differs between variants. A hidden section has no
// height, so this also runs when the Compare tab is shown.
function startScroll(){$$('.scroller').forEach(s=>{const im=s.querySelector('img');if(im&&im.clientHeight)s.scrollTop=(D.compare_start||0)*im.clientHeight})}
function drawCols(){
 const ids=$$('#chips input:checked').map(i=>i.value);
 $('#cols').innerHTML=ids.map(id=>`<div class="col"><h4>${esc(by[id].name)}</h4><div class="scroller"><img src="${img(id)}" data-zoom="${id}" alt=""></div></div>`).join('');
 const sc=$$('.scroller');let busy=false;
 sc.forEach(s=>{const im=s.querySelector('img');im.complete?startScroll():im.addEventListener('load',startScroll,{once:true})});
 sc.forEach(s=>s.addEventListener('scroll',()=>{if(busy)return;busy=true;sc.forEach(o=>{if(o!==s)o.scrollTop=s.scrollTop});requestAnimationFrame(()=>busy=false)}));
}
document.addEventListener('click',e=>{
 const t=e.target.closest('[data-tab]');if(t){$$('nav [data-tab]').forEach(b=>b.classList.toggle('on',b===t));$$('main section').forEach(s=>s.classList.toggle('on',s.id===t.dataset.tab));if(t.dataset.tab==='compare')startScroll();return}
 const th=e.target.closest('[data-th]');if(th){theme=th.dataset.th;$$('#theme button').forEach(b=>b.classList.toggle('on',b===th));
   const keep=$$('#chips input:checked').map(i=>i.value);render();$$('#chips input').forEach(i=>i.checked=keep.includes(i.value));drawCols();return}
 const z=e.target.closest('[data-zoom]');if(z){$('#lb img').src=img(z.dataset.zoom);$('#lb').style.display='block';return}
 if(e.target.closest('#lb'))$('#lb').style.display='none';
});
render();
</script></body></html>
"""


def main(argv):
    if len(argv) != 4:
        print(__doc__)
        return 2
    spec_path, out_dir, png_dir = Path(argv[1]), Path(argv[2]), Path(argv[3])
    spec = json.loads(spec_path.read_text())
    img_dir = out_dir / "img"
    img_dir.mkdir(parents=True, exist_ok=True)
    missing = []
    for v in spec["variants"]:
        for theme in ("light", "dark"):
            src = png_dir / f"{v['id']}-{theme}.png"
            if src.exists():
                shutil.copyfile(src, img_dir / src.name)
            else:
                missing.append(src.name)
    if missing:
        print("missing PNGs:", ", ".join(missing))
        return 1
    page = PAGE.replace("__TITLE__", spec.get("title", "Prototype")).replace(
        "__DATA__", json.dumps(spec).replace("</", "<\\/")
    )
    (out_dir / "index.html").write_text(page)
    print(out_dir / "index.html")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
