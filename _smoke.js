/* ══════════════════════════════════════════════════════════════
   🚨 배포 전 자동 점검 (스모크 테스트) — 컨텐츠의 모든것 (컨모)
   쓰는 법: 프리뷰를 «로그인한 상태»로 띄우고 콘솔에 아래 한 줄.
            fetch('/_smoke.js').then(r=>r.text()).then(t=>eval(t))
   결과가 표로 나오고 ❌가 하나라도 있으면 배포하지 않는다.
   설계: «이 앱에서 실제로 터진 사고»만 항목으로 만든다. 사고가 나면 여기 한 줄 추가.
   ⚠️ 읽기만 한다 — 어떤 데이터도 만들거나 지우거나 서버로 보내지 않는다.
   ══════════════════════════════════════════════════════════════ */
(async function smoke() {
  const R = [];
  const add = (name, ok, msg, level) => R.push({ name, ok: !!ok, msg: msg || '', level: level || 'err' });
  const warn = (name, ok, msg) => add(name, ok, msg, 'warn');
  const $id = i => document.getElementById(i);
  const src = (() => { let t = ''; for (const s of document.scripts) if ((s.text || '').length > t.length) t = s.text; return t; })();

  /* ── 1. 문법 — 스크립트가 통째로 죽으면 에러 0인데 앱이 안 움직인다 ── */
  try { new Function(src); add('스크립트 문법', true, (src.length / 1024).toFixed(0) + 'KB 파싱 OK'); }
  catch (e) { add('스크립트 문법', false, String(e.message).slice(0, 90)); }

  /* ── 2. 렌더 함수 생존 — 하나만 잘려도 그 화면이 통째로 빈다 ──
         (파이썬 일괄 치환이 «변수 선언까지» 먹은 사고 2회) */
  const FN = [
    'itemsLoad', 'itemsSave', 'itemsDel', 'newId', 'setOnline', 'cacheGet', 'cacheSet',   // 저장 계층
    'homeRender', 'vidRender', 'prRender', 'thRender', 'lnRender', 'musRender', 'scoreRender', // 강사실 5탭
    'stRender', 'rxRender', 'hwRender', 'toolRender', 'stuRender',                        // 수강생실 5탭
    'anatRender', 'anatRebuild', 'anatSents', 'paintAll',                                 // 해부 공정
    'shelfBlock', 'lecReady', 'vidTopics', 'vidKinds', 'vidAxes',                         // 강의 자료실
    'mrRender', 'mrLinkCard', 'mrReqCard',                                                // 마스터 실
    'showScr', 'setMode', 'inWs', 'sheetOpen', 'sheetClose', 'toast', 'pasteGuess',
  ];
  const missFn = FN.filter(f => src.indexOf('function ' + f) < 0);
  add('렌더 함수 생존', !missFn.length, missFn.length ? '사라짐: ' + missFn.join(', ') : FN.length + '개 모두 존재');

  /* ── 3. 필수 요소 생존 — 마크업에서 사라지면 «담기 버튼이 통째로 죽는» 사고(2회) ── */
  const IDS = ['dock', 'dock-s', 'mode', 'cws', 'toast', 'sheet', 'sheet-ov',
    'scr-s1', 'scr-s2', 'scr-s3', 'scr-s4', 'scr-s5', 'scr-anat',
    'scr-t1', 'scr-t2', 'scr-t3', 'scr-t4', 'scr-t5', 'scr-stu',
    'lg-ov', 'lg-code', 'lg-pin', 'lg-btn', 'tb-set', 'paste-in', 'paste-go'];
  const missId = IDS.filter(i => !$id(i));
  add('필수 요소 생존', !missId.length, missId.length ? '없음: ' + missId.join(', ') : IDS.length + '개 모두 존재');

  /* ── 4. 🚨 죽은 요소를 부르는 옛 코드 — 이 앱 최악의 사고(2회) ──
         마크업을 갈아끼웠는데 그 요소를 부르던 옛 줄이 남으면,
         에러 하나로 «그 아래 배선이 전멸»한다(버튼이 통째로 안 눌림). */
  const called = new Set();
  const re = /(?:getElementById\(|\$\(\s*)['"]#([a-zA-Z][a-zA-Z0-9_-]{2,})['"]/g;
  let m; while ((m = re.exec(src))) called.add(m[1]);
  // 동적으로 만들어지는 것은 제외 — 여기 적힌 접두어는 렌더 후 생긴다
  // scr- 는 '#scr-'+id 처럼 «조각으로 이어 붙이는» 이름이라 통째로는 존재하지 않는다
  const DYN = /^(scr-$|scr-|mr-|st-|rx-|hw-|vid-|pr-|th-|ln-|mus-|sc-|tl-|stu-|dp\d|sp\d|pw-|hm-|vf-|pf-|set-|lg-|tb-|t2seg|dseg|mrseg|judge-|swap-|offbar|home-date|anat)/;
  const ghosts = [...called].filter(i => !$id(i) && !DYN.test(i));
  warn('죽은 요소를 부르는 줄', !ghosts.length,
    ghosts.length ? '확인 필요: ' + ghosts.slice(0, 8).join(', ') : '없음');

  /* ── 5. 저장 id가 uuid인가 — 문자열 id로 저장해 «서버는 0행»이던 사고 ── */
  add('id = uuid', src.indexOf('randomUUID') > -1 && /4[0-9a-f]{3}|4xxx/.test(src),
    src.indexOf('randomUUID') > -1 ? 'crypto.randomUUID + 폴백 존재' : 'uuid 생성이 없다 — 서버가 행을 버린다');

  /* ── 6. 서버가 «200으로 주는 실패»를 보는가 — 앱은 담았다는데 서버는 0행이던 사고 ── */
  add('서버 실패 확인', src.indexOf('res.ok===false') > -1 || src.indexOf('res.ok === false') > -1,
    '저장 응답의 ok:false를 확인하는 줄');

  /* ── 7. 로그인 코드칸 IME — 한글 조합 중 대문자 변환이 value를 건드려
         «4자만 쳐지던» 사고(사장님 발견). isComposing 무시 + compositionend 처리가 있어야 한다 ── */
  add('로그인칸 한글 조합', src.indexOf('isComposing') > -1 && src.indexOf('compositionend') > -1,
    (src.indexOf('isComposing') > -1 ? '' : 'isComposing 없음 ') +
    (src.indexOf('compositionend') > -1 ? '' : 'compositionend 없음 ') || '조합 중 변환 차단됨');

  /* ── 8. 워크스페이스 선택자 — $('#mode b')가 배너 «안»의 칩까지 잡아
         관 스위치가 꺼지던 사고. 자식 선택자(>)여야 한다 ── */
  add('워크스페이스 선택자', src.indexOf("#mode > b") > -1 || src.indexOf("'#mode>b'") > -1,
    src.indexOf("#mode b'") > -1 ? "#mode b — 배너 안 칩까지 잡는다" : '자식 선택자 사용');

  /* ── 9. 도크에 이모지가 남았는가 — «스티커 같은 AI 느낌» 폐기 지시 ── */
  const dockTxt = [$id('dock'), $id('dock-s')].filter(Boolean).map(d => d.innerHTML).join('');
  const emoji = (dockTxt.match(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/gu) || []);
  add('도크 = 선화(이모지 0)', !emoji.length, emoji.length ? '남음: ' + emoji.join(' ') : 'SVG 선화만');
  const svgN = document.querySelectorAll('#dock button svg, #dock-s button svg').length;
  add('도크 아이콘 개수', svgN === 10, svgN + '개 (강사실 5 + 수강생실 5 = 10)');

  /* ── 10. 데이터 오염 — 빈 행이 서버로 실려 «분류 100»으로 집계되던 사고(마스터즈)
          컨모는 저장 전에 내용 있는 것만 거르는지 확인 ── */
  try {
    const raw = localStorage.getItem('cme-cache');
    if (raw) {
      const rows = JSON.parse(raw) || [];
      const empty = rows.filter(r => r && !r.title && !r.url && !r.body && !r.name && !r.text).length;
      warn('빈 행 오염', empty === 0, empty ? empty + '개 빈 행이 저장돼 있다' : '전체 ' + rows.length + '개, 빈 행 0');
    } else warn('빈 행 오염', true, '로컬 사본 없음(첫 실행)');
  } catch (e) { warn('빈 행 오염', false, '사본 파손: ' + e.message); }

  /* ── 11. 가로 넘침 — 폰에서 화면이 옆으로 밀리는 사고 ── */
  const de = document.documentElement;
  // 가로로 «일부러 스크롤되는 줄»(칩·커버플로우) 안에 있는 것은 넘침이 아니다
  const inScroller = el => {
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement)
      if (/auto|scroll/.test(getComputedStyle(p).overflowX)) return true;
    return false;
  };
  /* ⚠️ 판이 숨겨져 있으면 clientWidth가 0이라 «전부 화면 밖»으로 잡힌다(2026-08-19 오탐).
        잴 수 없는 상태를 «넘쳤다»고 말하지 않는다. */
  const over = de.clientWidth < 320 ? [] : [...document.querySelectorAll('.scr.on *')].filter(el => {
    const b = el.getBoundingClientRect();
    return b.width > 0 && (b.right > de.clientWidth + 2 || b.left < -2) && !inScroller(el);
  });
  if (de.clientWidth < 320) warn('가로 넘침', true, '판이 숨겨져 폭이 ' + de.clientWidth + 'px — 측정 못 함(판을 열고 다시)');
  else
  add('가로 넘침', !over.length && de.scrollWidth <= de.clientWidth + 2,
    over.length ? over.length + '개 요소가 화면 밖 (' + (over[0].className || over[0].tagName) + ' …)' : '없음');

  /* ── 12. 입력칸 16px — iOS가 자동으로 확대해버리는 사고 ── */
  const small = [...document.querySelectorAll('input,textarea,select')].filter(el => {
    if (!el.offsetParent) return false;
    return parseFloat(getComputedStyle(el).fontSize) < 16;
  });
  add('입력칸 16px', !small.length, small.length ? small.length + '개가 16px 미만 — iOS가 확대한다' : '전부 16px 이상');

  /* ── 13. CSS 접두어 충돌 — 짧은 이름이 다른 규칙에 조용히 먹히는 사고 ── */
  const shortCls = new Set();
  try {
    for (const sh of document.styleSheets) {
      let rules; try { rules = sh.cssRules; } catch (e) { continue; }
      for (const r of rules || []) {
        const sel = r.selectorText; if (!sel) continue;
        (sel.match(/\.[a-z]{1,3}[0-9]?\b/g) || []).forEach(c => shortCls.add(c));
      }
    }
  } catch (e) {}
  // 이 앱은 짧은 이름을 «부모 안에서만» 쓴다(.msd- 안의 .tt 등). 2자 이하 «단독» 규칙만 위험.
  const bare = [...shortCls].filter(c => c.length <= 3);
  warn('짧은 CSS 이름', bare.length < 40,
    bare.length + '개(2자 이하) — 새 규칙 추가 전 grep으로 선점 확인할 것');

  /* ── 14. 버전 일치 — sw.js를 안 올려 «배포했는데 안 바뀜» 1순위 사고 ── */
  try {
    const swTxt = await fetch('./sw.js', { cache: 'no-store' }).then(r => r.text());
    const swV = (swTxt.match(/CACHE_NAME\s*=\s*'([^']+)'/) || [])[1] || '?';
    const appV = (src.match(/ver:\s*'([^']+)'/) || [])[1] || '?';
    add('버전 일치', swV.indexOf(appV) > -1, 'APP_CFG ' + appV + ' / sw.js ' + swV);
  } catch (e) { warn('버전 일치', false, 'sw.js를 못 읽음'); }

  /* ── 15. 서버 연결 — demo:false인데 실제로 붙어 있는가 ── */
  add('서버 연결', !document.body.classList.contains('off'),
    document.body.classList.contains('off') ? '오프라인 배너가 떠 있다 — 저장이 안 된다' : '온라인');

  /* ── 16. 마스터 실 배선 — 서버 RPC 17개 중 앱이 부르는 것들 ── */
  const RPC = ['cm_req_list', 'cm_req_decide', 'cm_fb_send', 'cm_link_list', 'cm_link_decide', 'cm_link_off'];
  const missRpc = RPC.filter(r => src.indexOf(r) < 0);
  warn('마스터 실 RPC', !missRpc.length, missRpc.length ? '안 부름: ' + missRpc.join(', ') : RPC.length + '개 배선됨');

  /* ── 17. 「준비 중」 = 미구현 표시가 남았는가 — 빈 화면 4법칙 위반 ──
          ⚠️ 처방전의 «발급됨 ↔ 준비 중»은 상태 라벨이지 미구현이 아니다(.badge/.st 제외) ── */
  const soon = [...document.querySelectorAll('.scr')].filter(s => {
    const hits = [...s.querySelectorAll('*')].filter(el =>
      /^(준비\s*중|곧\s*만나요|공사\s*중)/.test((el.textContent || '').trim()) &&
      !el.matches('.badge,.st,.wait,.ac') && !el.children.length);
    return hits.length;
  }).map(s => s.id);
  add('미구현 표시 0개', !soon.length, soon.length ? '남음: ' + soon.join(', ') : '없음');

  /* ── 18. 🚨 하드코딩된 숫자 — 화면이 실데이터와 다른 말을 하는 사고 ──
          «수강생 12명»처럼 데이터가 0인데 헤드라인만 숫자를 외치면 앱이 거짓말이 된다 ── */
  const hard = (src.match(/수강생\s*<em>\d+명|전체\s*\d+명|\d+명 자라는 중/g) || []);
  add('하드코딩 숫자', !hard.length, hard.length ? '고정 숫자: ' + [...new Set(hard)].join(' · ') : '없음');

  /* ── 19. 🚨 세션 만료를 «오프라인»이라 말하는가 ──
          토큰이 죽었는데 «서버에 못 올리고 있어요»라고만 하면
          사용자는 계속 담고, 담은 것은 서버로 안 간다 — 다시 로그인할 길을 줘야 한다 ── */
  add('세션 만료 안내', /session/.test(src) && /(재로그인|다시 로그인|로그인이 풀)/.test(src),
    '서버가 session 오류를 줄 때 재로그인으로 안내하는 줄');

  /* ── 20. 🚨 발열 헌법 — 상시 반복 모션 금지(화면 안 쓰면 모션 OFF) ──
          v21 이전엔 배경 광원 둘이 26초·32초로 «항상» 돌았다. 로딩 표시만 예외. */
  var inf = [...document.querySelectorAll('*')].filter(function(el){
    var s = getComputedStyle(el);
    return s.animationName !== 'none' && s.animationIterationCount === 'infinite';
  });
  add('무한 반복 모션 0', !inf.length,
    inf.length ? inf.length + '개: ' + [...new Set(inf.map(e => e.className || e.tagName))].slice(0, 4).join(', ') : '없음');

  /* ── 21. 폰에 없는 hover가 «눌어붙는» 것 —
          가드 없는 :hover는 폰에서 한 번 누르면 그 상태로 남는다(문장이 칠해진 것처럼 보였다) ── */
  var hoverAll = 0, hoverGuarded = 0;
  try {
    for (const sh of document.styleSheets) {
      let rules; try { rules = sh.cssRules; } catch (e) { continue; }
      for (const r of rules || []) {
        if (r.selectorText && r.selectorText.indexOf(':hover') > -1) hoverAll++;
        if (r.media && /hover\s*:\s*hover/.test(r.conditionText || ''))
          for (const in2 of r.cssRules || []) if ((in2.selectorText || '').indexOf(':hover') > -1) { hoverAll++; hoverGuarded++; }
      }
    }
  } catch (e) {}
  add('hover 미디어 가드', hoverAll === 0 || hoverGuarded === hoverAll,
    hoverAll ? hoverGuarded + '/' + hoverAll + ' 가드됨' : ':hover 규칙 없음');

  /* ── 22. UX 마감이 실제로 붙어 있는가 (v21) ── */
  var uxOut = false, ux16 = false;
  try {
    for (const sh of document.styleSheets) {
      let rules; try { rules = sh.cssRules; } catch (e) { continue; }
      for (const r of rules || []) {
        if (r.selectorText === '.ux-out') uxOut = true;
        if (r.media && /768px/.test(r.conditionText || '') && /16px/.test(r.cssText || '')) ux16 = true;
      }
    }
  } catch (e) {}
  var body = document.body;
  warn('UX 마감 부착', uxOut && ux16 && typeof uxRowOut === 'function',
    (uxOut ? '' : '.ux-out 없음 ') + (ux16 ? '' : '입력칸 안전망 없음 ') +
    (typeof uxRowOut === 'function' ? '' : 'uxRowOut 없음 ') || '삭제 FLIP·입력칸 안전망·글씨 마감 모두 존재');

  /* ── 결과 ── */
  const bad = R.filter(r => !r.ok && r.level === 'err');
  const wr = R.filter(r => !r.ok && r.level === 'warn');
  console.log('%c 🧪 컨모 스모크 테스트 ', 'background:#C8F169;color:#050609;font-weight:900;padding:3px 10px;border-radius:6px');
  console.table(R.map(r => ({ '항목': r.name, '': r.ok ? '✅' : (r.level === 'warn' ? '⚠️' : '❌'), '내용': r.msg })));
  if (bad.length) console.log('%c ❌ 배포 금지 — ' + bad.length + '건 ',
    'background:#E07B7B;color:#fff;font-weight:900;padding:3px 10px;border-radius:6px', bad.map(b => b.name).join(' · '));
  else if (wr.length) console.log('%c ⚠️ 확인 후 배포 — ' + wr.length + '건 ',
    'background:#F0B24E;color:#050609;font-weight:900;padding:3px 10px;border-radius:6px', wr.map(b => b.name).join(' · '));
  else console.log('%c ✅ 전부 통과 — 배포해도 좋다 ',
    'background:#6FE0C8;color:#050609;font-weight:900;padding:3px 10px;border-radius:6px');
  window.__smoke = R;
  return { pass: R.length - bad.length - wr.length, warn: wr.length, fail: bad.length, rows: R };
})();
