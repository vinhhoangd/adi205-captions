import Foundation

/// The caption page every viewer loads. Embedded as a string so the binary has
/// no resource-bundle dependency: one file to copy, nothing to install. It is
/// plain HTML with no framework and no build step, which is what lets it open on
/// a Mac, an Ubuntu laptop, a Windows machine or a phone without changes.
public enum CaptionPage {
    /// Human-readable label for a language code, used on the tabs.
    public static func label(_ code: String) -> String {
        switch code {
        case "vi": return "Tiếng Việt"
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁體中文"
        default: return code
        }
    }

    public static func html(languages: [String]) -> String {
        let tabs = languages.map {
            "{code:\"\($0)\",label:\"\(label($0))\"}"
        }.joined(separator: ",")
        let firstName = languages.first.map(label) ?? "the translation"
        return """
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Live Captions</title>
        <style>
          :root{
            --bg:#0B0E11; --panel:#141A1F; --line:#222B33;
            --ink:#F2F6F8; --dim:#7A8792; --faint:#4A5560;
            --accent:#5BC8DE; --good:#4ED08A; --warn:#E8A44C; --bad:#E0645A;
          }
          @media (prefers-color-scheme: light){
            :root{
              --bg:#F4F6F7; --panel:#FFFFFF; --line:#DDE4E8;
              --ink:#11161A; --dim:#5E6B75; --faint:#95A2AC;
              --accent:#0E6577; --good:#1B7A4E; --warn:#9A6210; --bad:#B03A30;
            }
          }
          *{box-sizing:border-box;margin:0;padding:0}
          html,body{height:100%}
          body{
            background:var(--bg); color:var(--ink);
            font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,
                        "Helvetica Neue",Arial,"Noto Sans",sans-serif;
            display:flex; flex-direction:column; height:100vh;
            -webkit-font-smoothing:antialiased;
          }

          /* ── status bar ─────────────────────────────── */
          header{
            display:flex; align-items:center; gap:18px; flex:none;
            padding:10px 20px; border-bottom:1px solid var(--line);
            background:var(--panel); font-size:13px; color:var(--dim);
          }
          .grp{display:flex;align-items:center;gap:8px;white-space:nowrap}
          .dot{width:8px;height:8px;border-radius:50%;background:var(--bad);flex:none}
          .dot.on{background:var(--good)}
          .dot.warn{background:var(--warn)}

          /* ── record button ──────────────────────────── */
          .rec{
            display:flex;align-items:center;gap:9px;font:inherit;font-size:13px;
            font-weight:650;color:var(--bg);background:var(--good);
            border:none;border-radius:8px;padding:7px 15px;cursor:pointer;
          }
          .rec:hover{filter:brightness(1.08)}
          .rec.on{background:var(--bad)}
          .rec .glyph{
            width:11px;height:11px;flex:none;background:currentColor;
            clip-path:polygon(0 0,100% 50%,0 100%);   /* play triangle */
          }
          .rec.on .glyph{border-radius:2px;clip-path:none}  /* pause → square */
          .rec:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
          @keyframes pulse{0%,100%{opacity:1}50%{opacity:.45}}
          .dot.rec-on{background:var(--bad);animation:pulse 1.6s ease-in-out infinite}

          /* live input level — the thing that makes silence visible */
          .meter{
            width:84px;height:6px;border-radius:3px;background:var(--line);
            overflow:hidden;flex:none;
          }
          .meter i{
            display:block;height:100%;width:0%;border-radius:3px;
            background:var(--good);transition:width .12s linear;
          }
          .meter.quiet i{background:var(--warn)}
          .spacer{flex:1}
          .lat{font-variant-numeric:tabular-nums;color:var(--ink);font-weight:600}
          .lat.slow{color:var(--warn)}
          button{
            font:inherit;color:var(--dim);background:transparent;cursor:pointer;
            border:1px solid var(--line);border-radius:6px;padding:4px 10px;
          }
          button:hover{color:var(--ink);border-color:var(--faint)}
          button:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
          button.active{color:var(--ink);border-color:var(--accent)}

          /* ── warning strip ──────────────────────────── */
          .alert{
            flex:none;display:none;gap:10px;align-items:center;
            padding:9px 20px;background:var(--warn);color:#1a1205;
            font-size:13px;font-weight:600;
          }
          .alert.show{display:flex}

          /* ── captions ───────────────────────────────── */
          #feed{flex:1;overflow-y:auto;padding:28px 24px 45vh;scroll-behavior:smooth}
          .line{margin:0 auto 26px;max-width:56ch}
          .en{
            font-size:var(--size,34px); line-height:1.28; font-weight:650;
            letter-spacing:-.015em; margin:0 0 8px; overflow-wrap:break-word;
            transition:color .18s ease;
          }
          .en.live{color:var(--dim);font-weight:600}
          .tr{
            font-size:calc(var(--size,34px)*.82); line-height:1.34;
            color:var(--accent); overflow-wrap:break-word; font-weight:500;
          }
          .badge{
            display:inline-block;vertical-align:middle;margin-left:10px;
            font-size:11px;letter-spacing:.07em;text-transform:uppercase;
            font-weight:700;color:var(--good);border:1px solid var(--good);
            border-radius:20px;padding:1px 8px;
          }

          /* ── empty state ────────────────────────────── */
          #empty{
            flex:1;display:flex;flex-direction:column;align-items:center;
            justify-content:center;gap:18px;color:var(--dim);padding:24px;
          }
          #empty.hide{display:none}
          .wave{display:flex;align-items:flex-end;gap:5px;height:46px}
          .wave b{
            width:5px;border-radius:2px;background:var(--faint);
            height:6px;transition:height .1s ease,background .2s ease;
          }
          .wave.active b{background:var(--accent)}
          #emptyTitle{font-size:19px;font-weight:600;color:var(--ink)}
          #emptyHint{font-size:14px;text-align:center;max-width:40ch;line-height:1.5}

          /* ── language tabs ──────────────────────────── */
          .tabs{
            display:flex; gap:4px; flex:none; padding:8px 20px;
            border-bottom:1px solid var(--line); background:var(--panel);
            overflow-x:auto; scrollbar-width:none;
          }
          .tabs::-webkit-scrollbar{display:none}
          .tab{
            font:inherit; font-size:13px; font-weight:600; white-space:nowrap;
            color:var(--dim); background:transparent; border:1px solid transparent;
            border-radius:7px; padding:5px 13px; cursor:pointer;
          }
          .tab:hover{color:var(--ink)}
          .tab[aria-selected="true"]{
            color:var(--bg); background:var(--accent); border-color:var(--accent);
          }
          .tab:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
          /* In "All" the per-language lines need their own label */
          .trrow{display:flex;gap:10px;align-items:baseline}
          .trlang{
            flex:none; font-size:11px; font-weight:700; letter-spacing:.04em;
            color:var(--faint); min-width:5.5em; padding-top:.35em;
          }
          .kbd{
            font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;
            border:1px solid var(--line);border-radius:4px;padding:1px 6px;color:var(--ink);
          }
        </style></head><body>

        <header>
          <button class="rec" id="rec" title="Start or pause recording">
            <span class="glyph"></span><span id="recLabel">Start</span>
          </button>
          <span class="grp"><span class="dot" id="dot"></span><span id="state">connecting…</span></span>
          <span class="grp" title="Microphone input level">
            <span class="meter" id="meter"><i id="meterFill"></i></span>
            <span id="device">—</span>
          </span>
          <span class="spacer"></span>
          <span class="grp"><span class="lat" id="lat">—</span></span>
          <span class="grp">
            <button id="smaller" title="Smaller text">A−</button>
            <button id="bigger" title="Larger text">A+</button>
            <button id="pause" title="Stop following new captions">Auto-scroll</button>
          </span>
        </header>

        <div class="tabs" id="tabs" role="tablist"></div>

        <div class="alert" id="alert"><span>⚠</span><span id="alertText"></span></div>

        <div id="empty">
          <div class="wave" id="wave"><b></b><b></b><b></b><b></b><b></b><b></b><b></b></div>
          <div id="emptyTitle">Ready</div>
          <div id="emptyHint">Press <strong>Start</strong> to begin transcribing. \
        The microphone stays off until you do.</div>
        </div>

        <div id="feed" hidden></div>

        <script>
        (function(){
          var feed=document.getElementById('feed'), empty=document.getElementById('empty');
          var dot=document.getElementById('dot'), state=document.getElementById('state');
          var lat=document.getElementById('lat'), meter=document.getElementById('meter');
          var fill=document.getElementById('meterFill'), device=document.getElementById('device');
          var alertBox=document.getElementById('alert'), alertText=document.getElementById('alertText');
          var wave=document.getElementById('wave'), bars=wave.querySelectorAll('b');
          var size=34, follow=true, live=null, started=false, capturing=false;
          var LANGS=[\(tabs)];
          var view='all';   // 'all' or a single language code

          // Tabs: one per language, plus "All" when there is more than one.
          var tabBar=document.getElementById('tabs');
          function buildTabs(){
            var items=LANGS.slice();
            if(LANGS.length>1) items.push({code:'all',label:'All'});
            items.forEach(function(it){
              var b=document.createElement('button');
              b.className='tab'; b.textContent=it.label; b.dataset.code=it.code;
              b.setAttribute('role','tab');
              b.onclick=function(){ select(it.code); };
              tabBar.appendChild(b);
            });
            var saved=null;
            try{ saved=localStorage.getItem('capView'); }catch(e){}
            select(saved && items.some(function(i){return i.code===saved}) ? saved
                   : (LANGS.length>1 ? 'all' : LANGS[0].code));
          }
          function select(code){
            view=code;
            try{ localStorage.setItem('capView',code); }catch(e){}
            Array.prototype.forEach.call(tabBar.children,function(b){
              b.setAttribute('aria-selected', String(b.dataset.code===code));
            });
            // Re-render every line already on screen for the new selection.
            Array.prototype.forEach.call(document.querySelectorAll('.line'),function(l){
              renderTranslations(l, JSON.parse(l.dataset.tr||'{}'));
            });
            scroll();
          }

          // One translation line per language in "All", otherwise just the one.
          function renderTranslations(lineEl, trMap){
            var box=lineEl.querySelector('.trbox');
            box.innerHTML='';
            var codes = (view==='all') ? LANGS.map(function(l){return l.code}) : [view];
            codes.forEach(function(code){
              var text=trMap[code];
              if(!text) return;
              if(view==='all'){
                var row=document.createElement('div'); row.className='trrow';
                var lab=document.createElement('span'); lab.className='trlang';
                lab.textContent=labelFor(code);
                var p=document.createElement('p'); p.className='tr'; p.textContent=text;
                row.appendChild(lab); row.appendChild(p); box.appendChild(row);
              }else{
                var q=document.createElement('p'); q.className='tr'; q.textContent=text;
                box.appendChild(q);
              }
            });
          }
          function labelFor(code){
            for(var i=0;i<LANGS.length;i++) if(LANGS[i].code===code) return LANGS[i].label;
            return code;
          }

          function setSize(n){
            size=Math.max(18,Math.min(80,n));
            document.body.style.setProperty('--size',size+'px');
            try{localStorage.setItem('capSize',size)}catch(e){}
          }
          try{ var s=localStorage.getItem('capSize'); if(s) size=+s; }catch(e){}
          setSize(size);

          document.getElementById('bigger').onclick=function(){setSize(size+4)};
          document.getElementById('smaller').onclick=function(){setSize(size-4)};
          var pauseBtn=document.getElementById('pause');
          pauseBtn.classList.add('active');
          pauseBtn.onclick=function(){
            follow=!follow;
            pauseBtn.classList.toggle('active',follow);
            pauseBtn.textContent=follow?'Auto-scroll':'Paused';
            if(follow) scroll();
          };

          function scroll(){ if(follow) feed.scrollTop=feed.scrollHeight; }

          function liveLine(){
            if(!started){ started=true; empty.classList.add('hide'); feed.hidden=false; }
            if(!live){
              live=document.createElement('div'); live.className='line';
              live.innerHTML='<p class="en live"></p><div class="trbox"></div>';
              live.dataset.tr='{}';
              feed.appendChild(live);
            }
            return live;
          }

          // Input level drives both the header meter and the idle waveform, so a
          // dead microphone looks different from a quiet room at a glance.
          function showLevel(v){
            var pct=Math.min(100, Math.sqrt(v)*260);
            fill.style.width=pct+'%';
            meter.classList.toggle('quiet', v<0.002);
            wave.classList.toggle('active', v>=0.002);
            for(var i=0;i<bars.length;i++){
              var k=1-Math.abs(i-(bars.length-1)/2)/((bars.length-1)/2);
              bars[i].style.height=Math.max(6, pct*0.44*(0.45+k*0.55))+'px';
            }
          }

          // Recording control. The server owns the truth; the button sends an
          // intent and the next status event confirms what actually happened.
          var recBtn=document.getElementById('rec'), recLabel=document.getElementById('recLabel');
          var emptyTitle=document.getElementById('emptyTitle'), emptyHint=document.getElementById('emptyHint');
          recBtn.onclick=function(){
            var want = capturing ? 'pause' : 'start';
            recBtn.disabled=true;
            fetch('/control/'+want).catch(function(){}).then(function(){ recBtn.disabled=false; });
          };
          function setCapturing(on){
            if(on===capturing) return;
            capturing=on;
            recBtn.classList.toggle('on',on);
            recLabel.textContent=on?'Pause':'Start';
            if(!started){
              emptyTitle.textContent = on ? 'Listening' : 'Ready';
              emptyHint.innerHTML = on
                ? 'Speak toward the microphone. English appears first, \
        \(firstName) follows about a second later.'
                : 'Press <strong>Start</strong> to begin transcribing. \
        The microphone stays off until you do.';
            }
          }

          buildTabs();
          var es=new EventSource('/events');
          es.onopen=function(){ dot.className='dot on'; state.textContent='live'; };
          es.onerror=function(){
            dot.className='dot'; state.textContent='reconnecting…';
            alertText.textContent='Lost connection to the caption server.';
            alertBox.classList.add('show');
          };
          es.onmessage=function(ev){
            var d=JSON.parse(ev.data);

            if(d.kind==='status'){
              setCapturing(!!d.capturing);
              showLevel(d.level||0);
              device.textContent=d.device||'';
              if(!d.capturing){
                dot.className='dot'; state.textContent='paused';
                alertBox.classList.remove('show');
                return;
              }
              if(d.warning){
                dot.className='dot warn';
                alertText.textContent=d.warning;
                alertBox.classList.add('show');
                state.textContent='no audio';
              }else{
                dot.className='dot rec-on'; state.textContent='recording';
                alertBox.classList.remove('show');
              }
              return;
            }

            var el=liveLine();
            if(d.en) el.querySelector('.en').textContent=d.en;
            if(d.tr){ el.dataset.tr=JSON.stringify(d.tr); renderTranslations(el, d.tr); }

            if(d.kind==='finalized'){
              var en=el.querySelector('.en');
              en.className='en';
              if(d.corrected){
                var b=document.createElement('span');
                b.className='badge'; b.textContent='corrected';
                en.appendChild(b);
              }
              live=null;
            }
            if(d.latencyMS>0){
              lat.textContent=(d.latencyMS/1000).toFixed(1)+' s';
              lat.classList.toggle('slow', d.latencyMS>3000);
            }
            scroll();
          };
        })();
        </script></body></html>
        """
    }
}
