import Foundation

/// The caption page every viewer loads. Embedded as a string so the binary has
/// no resource-bundle dependency: one file to copy, nothing to install.
public enum CaptionPage {
    public static func html(target: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Live Captions</title>
        <style>
          :root {
            --bg:#0E1216; --panel:#161B20; --line:#2A323A;
            --en:#E7ECEF; --enDim:#7D8B95; --tr:#54C4DA; --meta:#6E7B85;
          }
          @media (prefers-color-scheme: light) {
            :root { --bg:#EEF1F3; --panel:#FFF; --line:#D4DCE1;
                    --en:#14181D; --enDim:#8894A0; --tr:#0E6577; --meta:#6E7B85; }
          }
          * { box-sizing:border-box; }
          body {
            margin:0; background:var(--bg); color:var(--en);
            font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
            display:flex; flex-direction:column; height:100vh;
          }
          header {
            display:flex; gap:16px; align-items:center; padding:10px 18px;
            border-bottom:1px solid var(--line); font-size:13px; color:var(--meta);
            flex:none;
          }
          .dot { width:9px;height:9px;border-radius:50%;background:#C0392B; flex:none; }
          .dot.on { background:#2ECC71; }
          .spacer { flex:1; }
          button {
            font:inherit; color:var(--meta); background:transparent;
            border:1px solid var(--line); border-radius:6px; padding:4px 10px; cursor:pointer;
          }
          button:hover { color:var(--en); }
          #feed { flex:1; overflow-y:auto; padding:22px 18px 40vh; }
          .line { margin:0 0 22px; }
          .en {
            font-size:var(--size,30px); line-height:1.32; font-weight:600;
            letter-spacing:-.01em; margin:0 0 6px; overflow-wrap:break-word;
          }
          .en.live { color:var(--enDim); }
          .tr {
            font-size:calc(var(--size,30px) * .86); line-height:1.36;
            color:var(--tr); margin:0; overflow-wrap:break-word;
          }
          .badge {
            font-size:11px; letter-spacing:.08em; text-transform:uppercase;
            color:var(--meta); border:1px solid var(--line); border-radius:20px;
            padding:1px 7px; margin-left:8px; vertical-align:middle;
          }
        </style></head><body>
        <header>
          <span class="dot" id="dot"></span><span id="status">connecting…</span>
          <span class="spacer"></span>
          <span id="lat">—</span>
          <button id="smaller">A−</button><button id="bigger">A+</button>
          <button id="pause">Pause scroll</button>
        </header>
        <div id="feed"></div>
        <script>
        const feed=document.getElementById('feed'), dot=document.getElementById('dot');
        const status=document.getElementById('status'), lat=document.getElementById('lat');
        let size=30, autoscroll=true, live=null;

        function setSize(n){ size=Math.max(16,Math.min(72,n));
          document.body.style.setProperty('--size', size+'px'); }
        document.getElementById('bigger').onclick=()=>setSize(size+4);
        document.getElementById('smaller').onclick=()=>setSize(size-4);
        document.getElementById('pause').onclick=e=>{
          autoscroll=!autoscroll; e.target.textContent=autoscroll?'Pause scroll':'Resume scroll'; };

        function liveLine(){
          if(!live){ live=document.createElement('div'); live.className='line';
            live.innerHTML='<p class="en live"></p><p class="tr"></p>'; feed.appendChild(live); }
          return live;
        }
        function scroll(){ if(autoscroll) feed.scrollTop=feed.scrollHeight; }

        const es=new EventSource('/events');
        es.onopen=()=>{ dot.classList.add('on'); status.textContent='live'; };
        es.onerror=()=>{ dot.classList.remove('on'); status.textContent='reconnecting…'; };
        es.onmessage=ev=>{
          const d=JSON.parse(ev.data), el=liveLine();
          if(d.kind==='finalized'){
            el.querySelector('.en').className='en';
            el.querySelector('.en').textContent=d.en;
            el.querySelector('.tr').textContent=d.tr;
            if(d.corrected){ const b=document.createElement('span');
              b.className='badge'; b.textContent='corrected';
              el.querySelector('.en').appendChild(b); }
            live=null;
          } else {
            if(d.en) el.querySelector('.en').textContent=d.en;
            if(d.tr) el.querySelector('.tr').textContent=d.tr;
          }
          if(d.latencyMS) lat.textContent=d.latencyMS+' ms';
          scroll();
        };
        setSize(size);
        </script></body></html>
        """
    }
}
