(function(){
'use strict';
var LOGO_D='{{LOGO_DARK}}';
function sv(p,extra){return '<svg class="i" viewBox="0 0 24 24"'+(extra||'')+'>'+p+'</svg>';}
var I={
 play:sv('<rect x="2" y="7" width="20" height="11" rx="5"/><path d="M7 11v3M5.5 12.5h3"/><circle cx="16" cy="11.5" r="1"/><circle cx="18" cy="13.5" r="1"/>'),
 create:sv('<path d="M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.6 2.6-2.4-.6-.6-2.4z"/>'),
 discover:sv('<circle cx="12" cy="12" r="9"/><path d="m15.5 8.5-2 5-5 2 2-5z"/>'),
 home:sv('<path d="M3 11 12 4l9 7v9h-6v-6H9v6H3z"/>'),
 party:sv('<circle cx="9" cy="8" r="3"/><circle cx="17" cy="9" r="2.5"/><path d="M3 20a6 6 0 0 1 12 0M14 20a4.5 4.5 0 0 1 7-3.7"/>'),
 friends:sv('<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>'),
 match:sv('<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5M8 11h6M11 8v6"/>'),
 chat:sv('<path d="M4 12a8 8 0 1 1 3.3 6.5L4 20l1.3-3.2A8 8 0 0 1 4 12z"/>'),
 voice:sv('<path d="M3 10v4M7 7v10M11 4v16M15 8v8M19 10v4"/>'),
 tasks:sv('<path d="m4 12 2 2 4-4M4 6l2 2 4-4M4 18l2 2 4-4M13 6h7M13 12h7M13 18h7"/>'),
 meet:sv('<rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10 5-3v10l-5-3"/>'),
 store:sv('<path d="M4 9h16l-1 11H5zM8 9V7a4 4 0 0 1 8 0v2"/>'),
 lib:sv('<rect x="4" y="4" width="4" height="16" rx="1"/><rect x="10" y="4" width="4" height="16" rx="1"/><path d="m16.5 5 3.5 14.5"/>'),
 heart:sv('<path d="M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z"/>'),
 star:sv('<path d="m12 3 2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z"/>'),
 mic:sv('<rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>'),
 micoff:sv('<path d="M15 9V6a3 3 0 0 0-6 0v6a3 3 0 0 0 4.5 2.6M5 11a7 7 0 0 0 11 5.7M19 11a7 7 0 0 1-.4 2.3M12 18v3M4 4l16 16"/>'),
 head:sv('<path d="M4 15v-3a8 8 0 0 1 16 0v3"/><rect x="3" y="14" width="4" height="6" rx="1.5"/><rect x="17" y="14" width="4" height="6" rx="1.5"/>'),
 x:sv('<path d="M6 6l12 12M18 6 6 18"/>'),
 plus:sv('<path d="M12 5v14M5 12h14"/>'),
 send:sv('<path d="M5 12h14M13 6l6 6-6 6"/>'),
 search:sv('<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>'),
 link:sv('<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>'),
 rocket:sv('<path d="M5 15c-1.5 1.5-2 5-2 5s3.5-.5 5-2M9 15l-3-3c1-4 5-9 13-9 0 8-5 12-9 13z"/><circle cx="15" cy="9" r="1.5"/>'),
 more:sv('<circle cx="5" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="19" cy="12" r="1.3"/>'),
 remix:sv('<path d="M4 7h11l-3-3M20 17H9l3 3M20 7v4M4 17v-4"/>'),
 globe:sv('<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>'),
 check:sv('<path d="m5 12 5 5 9-10"/>'),
 bang:sv('<path d="M12 5v9M12 19v.5"/>'),
 trophy:sv('<path d="M8 4h8v5a4 4 0 0 1-8 0zM8 6H4a3 3 0 0 0 4 4M16 6h4a3 3 0 0 1-4 4M12 13v4M8 20h8"/>'),
 bolt:sv('<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>'),
 flame:'<svg viewBox="0 0 24 24"><path d="M12 22c-4.4 0-7-3-7-6.6 0-4.4 4-6.4 3.6-11.4 3.4 1.6 5 4.2 5 6.8 1-1 1.6-2.2 1.6-3.8 2.6 2 3.8 4.8 3.8 8.2 0 3.8-2.6 6.8-7 6.8z"/></svg>',
 smile:sv('<circle cx="12" cy="12" r="9"/><path d="M8.5 14.5a4.5 4.5 0 0 0 7 0M9 9.5v.5M15 9.5v.5"/>'),
 back:sv('<path d="M15 5l-7 7 7 7"/>'),
 gift:sv('<rect x="3" y="9" width="18" height="12" rx="2"/><path d="M12 9v12M3 13h18M12 9C9 9 7 4 9.5 4S12 9 12 9zM12 9c3 0 5-5 2.5-5S12 9 12 9z"/>'),
 controller:sv('<path d="M6 9h12a4 4 0 0 1 3.9 4.8l-.7 3.4a2.5 2.5 0 0 1-4.3 1.2L14.5 16h-5l-2.4 2.4a2.5 2.5 0 0 1-4.3-1.2l-.7-3.4A4 4 0 0 1 6 9z"/><path d="M8 11.5v3M6.5 13h3"/>')
};
var STAR5='<span class="stars">'+[1,2,3,4,5].map(function(){return I.star;}).join('')+'</span>';
var P={J:['Player','#ff9a4a',14],M:['Maya','#ff6b8b',22],T:['Theo','#5fe3ff',19],P:['Priya','#ffd27a',31],S:['Sam','#b49bff',9],R:['rook_17','#7ef0a0',40,'r'],I:['mira','#ff8a7a',27,'m']};
function av(k,size,o){o=o||{};var p=P[k];var cls='av '+(size||'');if(o.ring)cls+=' ring '+(o.ring==='on'?'':o.ring);if(o.talk)cls+=' talk';
  return '<span class="'+cls+'" style="--c:'+p[1]+'" title="'+p[0]+'">'+(p[3]||k)+(o.lv?'<span class="lv">'+p[2]+'</span>':'')+'</span>';}
function seat(size){return '<span class="av empty '+(size||'')+'">+</span>';}
function partyAv(size){return '<span class="av party '+(size||'sm')+'">'+I.voice+'</span>';}
var EQ='<span class="eq"><i></i><i></i><i></i><i></i></span>';
var AG={lore:['Lore','var(--ag-purple)','L','game design'],forge:['Forge','var(--ag-brick)','F','art & 3D models'],atlas:['Atlas','var(--ag-green)','A','level design'],echo:['Echo','var(--ag-blue)','E','sound & music'],bridge:['Bridge','var(--ag-teal)','B','engine bridge'],oct:['Guide','var(--ag-orange)','O','your agent']};
function agAv(k,size){var a=AG[k];return '<span class="av agent '+(size||'sm')+'" style="--c:'+a[1]+'" title="'+a[0]+'">'+a[2]+'</span>';}
var PARTY_GAME='maneframe';
function ttl(id,cls){var g=GM[id];return '<span class="ttl tf-'+g.tf+(cls?' '+cls:'')+'">'+g.title+'</span>';}
/* art(id,{tags,meta,ttl:false,tile:false,vb,h,fs}) : the cover block. Tiles are focusable and open the game page. */
function art(id,o){o=o||{};var g=GM[id],t=o.tile!==false;
  return '<div class="art scrim'+(t?' tile':'')+'"'+(t?' tabindex="0" role="button" data-nav data-game="'+id+'" aria-label="'+g.title+'"':'')+' style="--gt:'+g.tint+(o.h?';height:'+o.h+'px':'')+'">'+cover(id,{vb:o.vb,pos:o.pos})+(o.tags?'<span class="tags'+(o.tr?' r':'')+'">'+o.tags+'</span>':'')+(o.meta||'')+(o.ttl===false?'':ttl(id).replace('class="ttl','class="ttl'+(o.fs?'" style="font-size:'+o.fs+'px':'')))+'</div>';}
function priceStk(g){return g.dev?'<span class="stk pink">In Create</span>':'<span class="stk'+(g.price==='Free'?' mint':'')+'">'+g.price+'</span>';}
function gcard(id,o){o=o||{};var g=GM[id];
  return '<div class="gcard">'+(o.rank?'<span class="rank">'+o.rank+'</span>':'')+art(id,{tags:o.tags,fs:o.fs,tr:!!o.rank})+'<div class="cap"><b>'+g.title+'</b><span>'+(o.sub||g.genre+' · '+g.players)+'</span></div></div>';}
function shelf(title,ids,o){o=o||{};
  return '<div class="shelfwrap"><div class="h-sec"><h3>'+title+(o.badge||'')+'</h3>'+(o.link?'<a data-go="'+(o.go||'library')+'">'+o.link+'</a>':'')+'</div><div class="shelf'+(o.big?' big':'')+'">'+ids.map(function(id,i){return gcard(id,{rank:o.ranked?'#'+(i+1):'',tags:o.tagf?o.tagf(id,i):'',sub:o.subf?o.subf(id,i):''});}).join('')+'</div>'+
  '<div class="focusbar">'+(o.hint?'<span class="kbd"><kbd>←</kbd><kbd>→</kbd> move <kbd>↑</kbd><kbd>↓</kbd> rows <kbd>Enter</kbd> open</span>':'')+'</div></div>';}

var S={mode:'play',screen:'play-home',nav:'switcher',vote:'maneframe',gameTab:'overview',pcMin:false,game:'maneframe'};
var MODES={
 play:{label:'Play',icon:'play',items:[['play-home','home','Tonight'],['party','party','Parties','badge:1'],['friends','friends','Friends','on:6 on'],['lfg','match','Find players']]},
 create:{label:'Create',icon:'create',items:[['create','chat','Chat','badge:3'],['create-voice','voice','Voice'],['create-tasks','tasks','Tasks'],['create-meet','meet','Meetings']],more:['Files','Canvases','Agents','Skills','Builds']},
 discover:{label:'Discover',icon:'discover',items:[['store','store','Store'],['library','lib','Library','cnt:15'],['wish','heart','Wishlist'],['creators','star','Creators']]}
};
var SCREENS={
 'play-home':{mode:'play',details:true},'party':{mode:'play',details:true},'friends':{mode:'play',details:true},'lfg':{mode:'play',details:true},
 'create':{mode:'create',list:true,details:true},'create-tasks':{mode:'create',list:true,details:true},'create-voice':{mode:'create',list:true,details:true},'create-meet':{mode:'create',list:true,details:true},
 'store':{mode:'discover'},'game':{mode:'discover',details:true},'library':{mode:'discover'},'wish':{mode:'discover'},'creators':{mode:'discover'},
 'phone':{mode:'play',phone:true}
};
function readHash(){
  (location.hash||'').replace(/^#/,'').split('&').forEach(function(p){
    if(!p) return;
    if(p==='tabs'||p==='switcher') S.nav=p;
    else if(p==='min') S.pcMin=true;
    else if(p.indexOf('g=')===0&&GM[p.slice(2)]) S.game=p.slice(2);
    else if(SCREENS[p]){S.screen=p;S.mode=SCREENS[p].mode;}
  });
}
function go(s){S.screen=s;S.mode=SCREENS[s].mode;sync();}
function sync(){var h=[S.screen,S.nav];if(S.screen==='game')h.push('g='+S.game);if(S.pcMin)h.push('min');try{history.replaceState(null,'','#'+h.join('&'));}catch(e){}render();var m=document.querySelector('.mbody');if(m)m.scrollTop=0;}
function brand(){return '<span class="brand-lock"><img src="'+LOGO_D+'" alt="Burrow"><span class="play-tag">PLAY</span></span>';}

/* ---------- nav A: side rail ---------- */
function sideHTML(){
  var m=MODES[S.mode], o='';
  o+='<div class="brand">'+brand()+'<span class="sp"></span><button class="icon-btn" title="Jump anywhere">'+I.search+'</button></div>';
  o+='<div class="modes" role="tablist">'+['play','create','discover'].map(function(k){return '<button data-mode="'+k+'" aria-current="'+(S.mode===k?'page':'false')+'">'+I[MODES[k].icon]+MODES[k].label+'</button>';}).join('')+'</div><div class="sc">';
  m.items.forEach(function(it){
    var extra='';
    if(it[3]){var p=it[3].split(':');extra=p[0]==='badge'?'<span class="badge">'+p[1]+'</span>':'<span class="cnt'+(p[0]==='on'?' on':'')+'">'+p[1]+'</span>';}
    o+='<button class="nav" data-go="'+it[0]+'" aria-current="'+(S.screen===it[0]?'page':'false')+'">'+I[it[1]]+it[2]+extra+'</button>';
  });
  if(m.more){o+='<div class="lbl">More</div>';m.more.forEach(function(x){o+='<button class="nav" data-go="create"><span class="hash">·</span>'+x+'</button>';});}
  if(S.mode==='create'){
    o+='<div class="lbl">Projects <button>'+I.plus+'</button></div>';
    o+='<button class="nav" data-go="create"><span class="av agent xs" style="--c:#7a85ff">M</span>Moon Lions<span class="sub">game</span></button>';
    o+='<button class="nav" data-go="create"><span class="av agent xs" style="--c:#b98bff">F</span>Mane Frame<span class="sub">live</span></button>';
  }
  o+='<div class="lbl">Chat <button title="New message">'+I.plus+'</button></div>';
  o+='<button class="nav" data-go="party">'+partyAv('xs')+'Friday lions'+EQ+'</button>';
  o+='<button class="nav" data-go="party">'+av('M','xs')+'Maya</button>';
  o+='<button class="nav" data-go="party">'+av('T','xs')+'Theo<span class="badge">2</span></button>';
  o+='<button class="nav" data-go="party">'+av('P','xs')+'Priya<span class="sub">Moth Lantern</span></button>';
  o+='<button class="nav" data-go="game" data-g="maneframe"><span class="av chan xs">#</span>maneframe-players<span class="cnt">1.2k</span></button>';
  o+='<button class="nav" data-go="create">'+agAv('oct','xs')+'Guide<span class="sub">your agent</span></button>';
  o+='<div class="grow"></div></div><div class="ft">';
  o+='<div class="voicebar"><div class="t"><span class="livedot"></span>Friday lions'+EQ+'</div><div class="s"><span class="pile">'+av('J','xs')+av('M','xs')+av('T','xs')+'</span>picking a game</div><div class="c"><button title="Mute">'+I.mic+'</button><button title="Deafen">'+I.head+'</button><button data-go="party" title="Open party">'+I.party+'</button><button class="leave" title="Leave">'+I.x+'</button></div></div>';
  o+='<button class="user">'+av('J','md',{ring:'on'})+'<span class="who"><b>Player<em>LV 14</em></b><span class="xp"><i style="width:72%"></i></span><small>2,160 / 3,000 XP · online</small></span></button></div>';
  return o;
}
/* ---------- nav B: console top bar ---------- */
function topbarHTML(){
  var m=MODES[S.mode];
  return brand()+'<div class="tabs3">'+['play','create','discover'].map(function(k){return '<button data-mode="'+k+'" aria-current="'+(S.mode===k?'page':'false')+'">'+I[MODES[k].icon]+MODES[k].label+'</button>';}).join('')+'</div>'+
  '<div class="subnav">'+m.items.map(function(it){var b=it[3]&&it[3].indexOf('badge')===0?'<span class="badge">'+it[3].split(':')[1]+'</span>':'';return '<button data-go="'+it[0]+'" aria-current="'+(S.screen===it[0]?'page':'false')+'">'+it[2]+b+'</button>';}).join('')+'</div>'+
  '<span style="flex:1"></span><button class="icon-btn" title="Search">'+I.search+'</button><button class="vpill" data-go="party"><span class="pile">'+av('J','xs')+av('M','xs')+av('T','xs')+'</span>Friday lions'+EQ+'</button><span class="clock">9:41</span>'+av('J','sm',{ring:'on'});
}

/* ---------- PLAY ---------- */
var LIB3=['kart','moth','glacier','tide','ruin','garden','neon','cards'];
function playHome(){
  var g=GM[PARTY_GAME];
  var o='<div class="mhead"><h1>Tonight<small><span class="pill ok"><i></i>6 friends online</span></small></h1><span class="sp"></span><button class="ghost">'+I.link+'Invite link</button><button class="primary" data-go="party">'+I.plus+'Start a party</button></div><div class="mbody">';
  o+='<div class="hero">'+art(PARTY_GAME,{tile:false,ttl:false})+'<div class="copy"><div class="tagrow"><span class="stk pink"><span class="livedot"></span>3 in party</span><span class="stk mint">Free</span><span class="stk">25 min</span></div>'+ttl(PARTY_GAME,'gtitle')+'<p>Three of you are around. 5-player co-op, you, Maya and Theo own it, controllers OK.</p><div class="seats">'+av('J','sm',{ring:'voice'})+av('M','sm',{ring:'voice',talk:1})+av('T','sm',{ring:'voice'})+seat('sm')+seat('sm')+'<span class="lab">Fits your crew · 2 open seats</span></div><div class="cta"><button class="primary lg" data-go="party" data-nav>'+I.play+'Join Friday lions</button><button class="ghost lg" data-go="party" data-nav>'+I.globe+'Fill seats</button></div></div>';
  o+='</div>';
  o+=shelf('Your library, ranked for three',LIB3,{ranked:1,link:'Library',hint:1,tagf:function(id,i){return i===0?'<span class="stk solid">Party</span>':id==='glacier'?'<span class="stk mint">New</span>':'';}});
  o+=shelf('New on Burrow this week',['neon','deep','sky','pixel','desert','hex'],{link:'Store',go:'store',tagf:function(id){return priceStk(GM[id]);}});
  o+=shelf('Jump back in',['moonlions','hex','moth','kart'],{subf:function(id){return id==='moonlions'?'Your project · build 14':'Last played '+({hex:'yesterday',moth:'2 days ago',kart:'last week'})[id];},tagf:function(id){return id==='moonlions'?'<span class="stk pink">In Create</span>':'';}});
  o+='<div class="oq" style="max-width:620px;margin:8px 4px 40px"><b>Open question</b>“Fill seats” = matchmaking with strangers. Default off, friends-of-friends first?</div>';
  return o+'</div>';
}
var FRIENDS=[['M','In Friday lions','maneframe','voice',1],['T','In Friday lions','maneframe','voice',0],['P','Moth Lantern · 2/4','moth','on',0],['S','Building Moon Lions','moonlions','on',0],['I','Mossling Garden','garden','on',0],['R','Neon Drift Club','neon','away',0]];
function playDetails(){
  var o='<div class="dhead"><b>Party</b><button class="icon-btn">'+I.plus+'</button></div><div class="dbody">';
  o+='<div class="pcard"><div class="hd">'+partyAv('md')+'<b>Friday lions</b>'+EQ+'</div><div class="vs">'+['J','M','T'].map(function(k){return '<span class="s">'+av(k,'md',{ring:'voice',talk:k==='M'})+(k==='J'?'You':P[k][0])+'</span>';}).join('')+'<span class="s">'+seat('md')+'open</span></div><div class="now">Voting: Mane Frame 2 · Kart 1</div><div class="stack"><button class="primary" data-go="party" data-nav>Open party</button></div></div>';
  o+='<div class="section-label"><span class="livedot"></span>Friends online · 6</div>';
  FRIENDS.forEach(function(f){o+='<div class="frow" tabindex="0" role="button" data-nav data-go="party">'+av(f[0],'md',{ring:f[3],talk:f[4]})+'<span class="txt"><b>'+P[f[0]][0]+'</b><span class="act'+(f[3]!=='away'?' on':'')+'">'+f[1]+'</span></span>'+art(f[2],{tile:false,ttl:false}).replace('class="art scrim','class="art mini')+'</div>';});
  o+='<div class="section-label">Invites</div><div class="panel tight"><div style="display:flex;gap:11px;align-items:center;margin-bottom:12px">'+av('P','sm')+'<div><b style="font-size:13.5px;font-weight:600">Priya invited you</b><div style="font-size:var(--fs-sm);color:var(--muted)">“lantern run, need a 3rd”</div></div></div><div class="segs"><button class="primary" data-go="party">Join</button><button class="ghost">Later</button></div></div>';
  o+='<div class="streak">'+I.flame+'<span class="num">3</span><span><b>Night streak</b><span>Play with Maya tonight to keep it</span></span></div>';
  o+='<div class="section-label">Friend activity</div><div class="feed">'+
  '<div class="fe"><span class="ic" style="--c:var(--gold)">'+I.trophy+'</span><span><b>Maya</b> unlocked Titan Form</span><time>2m</time></div>'+
  '<div class="fe"><span class="ic" style="--c:var(--pink)">'+I.bolt+'</span><span><b>Theo</b> hit level 19</span><time>1h</time></div>'+
  '<div class="fe"><span class="ic" style="--c:var(--violet)">'+I.rocket+'</span><span><b>Sam</b> shipped build 14</span><time>3h</time></div></div>';
  return o+'</div>';
}
function msg(k,txt){if(k==='me')return '<div class="msg me">'+av('J','sm')+'<div class="bubble">'+txt+'</div></div>';
  var who=P[k];return '<div class="msg">'+av(k,'sm')+'<div class="bubble"><span class="from" style="--c:'+who[1]+'">'+who[0]+'</span>'+txt+'</div></div>';}
function agMsg(k,label,txt){var a=AG[k];return '<div class="msg">'+agAv(k,'sm')+'<div class="bubble agent" style="--c:'+a[1]+'"><span class="from">'+label+'</span>'+txt+'</div></div>';}
function party(){
  var o='<div class="mhead">'+partyAv('md')+'<h1>Friday lions<small><span class="pill pk"><i></i>3 in voice</span></small></h1><span class="sp"></span><button class="ghost">'+I.link+'Invite</button><button class="primary">'+I.rocket+'Launch '+GM[S.vote].title.split(':')[0]+'</button></div><div class="mbody">';
  o+='<div class="eyebrow" style="margin:6px 4px 0">'+I.trophy+'Pick a game together · 3 from your shared library</div><div class="votes">';
  [['maneframe',2,'everyone owns it · 5 seats',['J','T']],['kart',1,'Priya doesn’t own it · $4',['M']],['moth',0,'2–4 players',[]]].forEach(function(v){var g=GM[v[0]];
    o+='<button class="vote" data-nav data-vote="'+v[0]+'" aria-pressed="'+(S.vote===v[0])+'">'+(S.vote===v[0]?'<span class="pick stk solid">Your pick</span>':'')+art(v[0],{tile:false})+'<div class="vinfo"><span class="txt"><b>'+g.title+'</b><span>'+v[2]+'</span></span><span class="pile">'+v[3].map(function(k){return av(k,'xs');}).join('')+'</span><span class="n">'+v[1]+'<small>vote'+(v[1]===1?'':'s')+'</small></span></div><div class="bar"><i style="width:'+(v[1]/3*100)+'%"></i></div></button>';});
  o+='</div><div style="display:grid;grid-template-columns:minmax(0,1.4fr) minmax(0,1fr);gap:16px;padding:14px 4px 30px;align-items:start">';
  o+='<div class="panel" style="padding:0;display:flex;flex-direction:column;height:430px"><div class="chat"><div class="msgs"><div class="day">Tonight</div>'+msg('T','lions at 9? bring a mic')+msg('me','in. Maya you on?')+msg('M','yes but i want kart after');
  o+='<div class="sysline">'+I.trophy+'Theo started a vote</div>';
  o+=agMsg('oct','Guide','All three of you have Mane Frame on the same build (d4afd4e). Maya’s mic is quiet, so I nudged her input gain.');
  o+='<div class="card" style="margin-left:38px"><span class="thumb">'+art('maneframe',{ttl:false,tile:false})+'</span><span class="ct"><b>Mane Frame is ready</b><span>Lobby on the match server · 3/5 seats</span></span><span class="stk mint">Ready</span></div>';
  o+='</div><div class="composer"><div class="box"><button class="emo" title="Reactions">'+I.smile+'</button><input placeholder="Message Friday lions"><button class="emo" title="Send a clip">'+I.gift+'</button><button class="send">'+I.send+'</button></div></div></div></div>';
  o+='<div><div class="panel tight"><div class="eyebrow" style="margin-bottom:6px">'+I.mic+'Voice check</div>';
  var ok='<span class="d ok">'+I.check+'</span>',wa='<span class="d wa">'+I.bang+'</span>';
  o+='<div class="check">'+ok+'Your mic <div class="meter">'+[1,1,1,1,1,1,1,1,1,1,0,0,0,0].map(function(x,i){return '<i class="'+(x?(i>7?'hot':'on'):'')+'"></i>';}).join('')+'</div></div><div class="check">'+ok+'Theo · good</div><div class="check">'+wa+'Maya · quiet, gain raised</div><div class="check">'+ok+'Everyone on build d4afd4e</div><div class="check">'+ok+'Controllers: 3 detected</div></div>';
  o+='<div class="oq"><b>Open question</b>Is a party a Burrow channel (persists, has history, agents can join) or a temporary room that disappears after the session?</div></div></div>';
  return o+'</div>';
}
function partyDetails(){
  var o='<div class="dhead"><b>In voice · 3</b>'+EQ+'<button class="icon-btn">'+I.more+'</button></div><div class="dbody"><div class="vgrid">';
  o+='<div class="vt talking">'+av('J','lg',{ring:'voice',talk:1,lv:1})+'You<small>talking</small></div>';
  o+='<div class="vt">'+av('M','lg',{ring:'voice',lv:1})+'Maya<small>quiet · gain up</small></div>';
  o+='<div class="vt talking">'+av('T','lg',{ring:'voice',talk:1,lv:1})+'Theo<small>talking</small></div>';
  o+='<div class="vt">'+agAv('oct','lg')+'Guide<small>listening</small></div>';
  o+='<div class="vt seat">'+seat('lg')+'Open seat</div><div class="vt seat">'+seat('lg')+'Open seat</div></div>';
  o+='<div class="segs" style="padding:10px 0"><button class="ghost">'+I.mic+'Mute</button><button class="ghost">'+I.head+'Deafen</button><button class="ghost">Push to talk</button></div>';
  o+='<div class="section-label">Invite</div><div class="row">'+av('P','sm',{ring:'on'})+'<span class="txt"><span class="name">Priya</span><span class="last">Playing Moth Lantern</span></span><button class="ghost">Invite</button></div><div class="row">'+av('S','sm',{ring:'on'})+'<span class="txt"><span class="name">Sam</span><span class="last">In Create · Moon Lions</span></span><button class="ghost">Invite</button></div><div class="row"><span class="av chan sm">'+I.link+'</span><span class="txt"><span class="name">Copy party link</span><span class="last">Friends only · expires in 2h</span></span></div>';
  o+='<div class="section-label">Fill seats with players</div><div class="panel tight"><div class="segs" style="margin-bottom:12px"><button class="seg" aria-pressed="true">Friends of friends</button><button class="seg">Game community</button><button class="seg">Anyone</button></div><p style="margin:0">Matched players join this game only. Voice is push-to-talk until you add them. Report and block on every avatar.</p></div>';
  o+='<div class="oq"><b>Open question</b>Strangers: what is the safety floor (age gate, voice off by default, party leader kick, report → who reviews)?</div>';
  return o+'</div>';
}

/* ---------- CREATE (existing Burrow flows, game presets, glass skin) ---------- */
function createList(){
  var o='<div class="lhead"><h2>Moon Lions<small>Godot · 3 people · 5 agents</small></h2><button class="icon-btn">'+I.plus+'</button></div><div class="projban">'+art('moonlions',{tile:false,ttl:false,tags:'<span class="stk pink">Build 14</span>'})+'</div><div style="padding:6px 12px 0"><input class="search" placeholder="Search"></div><div class="lbody">';
  o+='<div class="section-label">Channels</div>';
  [['general','Sam: pushed the arena blockout',1],['design','Lore: core loop draft v2',0],['levels','Atlas: arena 2 ready to playtest',2],['art','Forge: 3 lion variants',0],['sound','Echo: roar pack v1',0],['playtests','build 14 · 4 notes',0]].forEach(function(c,i){
    o+='<button class="row" data-go="create" aria-current="'+(i===2&&S.screen==='create'?'true':'false')+'"><span class="av chan sm">#</span><span class="txt"><span class="name">'+c[0]+(c[2]?'<time class="new">'+c[2]+' new</time>':'<time>today</time>')+'</span><span class="last">'+c[1]+'</span></span></button>';
  });
  o+='<div class="section-label">Agents in this project</div>';
  ['lore','forge','atlas','echo','bridge'].forEach(function(k){var a=AG[k];o+='<button class="row">'+agAv(k)+'<span class="txt"><span class="name">'+a[0]+'</span><span class="last">'+a[3]+'</span></span></button>';});
  return o+'</div>';
}
function createChat(){
  var tasks=S.screen==='create-tasks';
  var o='<div class="mhead"><h1># levels</h1><span class="sp"></span><div class="segs" style="background:rgba(255,255,255,.06);padding:4px;border-radius:999px"><button class="seg" data-go="create" aria-pressed="'+(!tasks)+'">Chat</button><button class="seg" data-go="create-tasks" aria-pressed="'+tasks+'">Tasks</button></div><button class="primary" data-go="party">'+I.play+'Playtest</button></div>';
  if(tasks) return o+createBoard();
  o+='<div class="chat"><div class="msgs"><div class="day">Today</div>';
  o+=msg('S','arena 2 feels too open, lions never meet up');
  o+=agMsg('atlas','Atlas · level design','Pulled the spawn rings 30% closer and added two choke bridges. Pushed to Godot as <b>arena_02.tscn</b>; Bridge rebuilt it.');
  o+='<div class="card" style="margin-left:38px"><span class="thumb">'+art('moonlions',{ttl:false,tile:false,vb:'120 40 200 112'})+'</span><span class="ct"><b>Build 14 · arena 2</b><span>Godot 4.7 · Windows · playable in a party now</span></span><button class="ghost" data-go="party">Play</button></div>';
  o+=msg('me','@Echo can the bridges creak when a lion lands?');
  o+=agMsg('echo','Echo · sound','Three creak takes, mapped to landing impulse. Opened task <b>Bridge creak SFX</b> for review.');
  o+=agMsg('forge','Forge · art','Three lion variants for the moon arena. Pick one and I’ll rig it.');
  o+='<div style="display:flex;gap:12px;margin-left:38px">'+['150 20 150 84','182 52 84 47','150 76 150 84'].map(function(vb,i){return '<div style="width:150px">'+art('moonlions',{ttl:false,vb:vb,tile:false,h:84}).replace('class="art scrim"','class="art tile" tabindex="0" data-nav')+'<div style="font-size:11.5px;color:var(--muted);margin-top:6px;padding-left:4px">Variant '+(i+1)+'</div></div>';}).join('')+'</div>';
  o+='</div><div class="composer"><div class="box"><button class="emo">'+I.plus+'</button><input placeholder="Message #levels · @ an agent"><button class="send">'+I.send+'</button></div></div></div>';
  return o;
}
function createBoard(){
  var cols=[['Idea','var(--violet)',[['Lion combine animation','forge','Forge'],['Low-gravity jump arcs','lore','Lore']]],['In progress','var(--blue)',[['Arena 2 choke bridges','atlas','Atlas',1],['Roar pack v2','echo','Echo']]],['Playtest','var(--pink)',[['Build 14 · arena 2','bridge','Bridge']]],['Done','var(--mint)',[['Core loop v2','lore','Lore'],['Spawn rings','atlas','Atlas']]]];
  var o='<div class="mbody"><div class="board">';
  cols.forEach(function(c){o+='<div class="col" style="--c:'+c[1]+'"><h4><span style="all:unset;display:flex;align-items:center"><i></i>'+c[0]+'</span><span>'+c[2].length+'</span></h4>';c[2].forEach(function(t){o+='<div class="tcard" tabindex="0" data-nav><b>'+t[0]+'</b><div class="who">'+agAv(t[1],'xs')+t[2]+(t[3]?'<span class="pill acc" style="margin-left:auto"><i></i>running</span>':'')+'</div><div class="stages"><i class="done"></i><i class="'+(t[3]?'running':'done')+'"></i><i'+(c[0]==='Done'?' class="done"':'')+'></i></div></div>';});o+='</div>';});
  return o+'</div><div class="oq" style="max-width:560px;margin:0 4px"><b>Note</b>This is the existing Burrow Tasks board, unchanged underneath. Only the project template (columns, starter tasks, agents) and the Play skin are game-flavoured.</div></div>';
}
function createDetails(){
  var o='<div class="dhead"><b>Project</b><button class="icon-btn">'+I.more+'</button></div><div class="dbody">';
  o+='<div class="section-label">Engine</div>';
  o+='<div class="eng on"><span class="logo" style="--c:#5fe3ff">Gd</span><span class="txt"><b>Godot 4.7</b><span>Bridge connected · built 2 min ago</span></span><span class="pill ok"><i></i>live</span></div>';
  o+='<div class="eng"><span class="logo" style="--c:#cfd3ee">Ue</span><span class="txt"><b>Unreal 5</b><span>not connected</span></span><button class="ghost">Connect</button></div>';
  o+='<div class="eng"><span class="logo" style="--c:#cfd3ee">Un</span><span class="txt"><b>Unity 6</b><span>not connected</span></span><button class="ghost">Connect</button></div>';
  o+='<div class="section-label">Skill agents (preset)</div>';
  ['lore','forge','atlas','echo','bridge'].forEach(function(k){var a=AG[k];o+='<div class="row">'+agAv(k)+'<span class="txt"><span class="name">'+a[0]+'</span><span class="last">'+a[3]+'</span></span>'+(k==='atlas'?'<span class="pill acc"><i></i>working</span>':'<span class="pill">idle</span>')+'</div>';});
  o+='<button class="ghost" style="margin:8px 4px">'+I.plus+'Add a skill agent</button>';
  o+='<div class="section-label">What makes a game</div><div class="panel tight"><div class="comp"><span class="done">DES</span><span class="done">ART</span><span class="run">LVL</span><span class="run">SFX</span><span class="done">CODE</span><span>TEST</span><span>PUB</span></div><p style="margin:10px 0 0;font-size:var(--fs-xs)">The components, as a map, not a pipeline. Any agent can work on any of them in any order.</p></div>';
  o+='<button class="primary lg" style="margin:16px 0 4px;width:100%">'+I.rocket+'Publish to Discover</button>';
  return o+'</div>';
}

/* ---------- DISCOVER ---------- */
var FEAT='desert';
function friendsOn(id){return {moth:'P',kart:'M',garden:'I',neon:'R',maneframe:'T',tide:'T',hex:'S'}[id];}
function store(){
  var g=GM[FEAT];
  var o='<div class="mhead"><h1>Store<small>games made on Burrow</small></h1><span class="sp"></span><input class="search" style="width:300px" placeholder="Search games and creators"></div><div class="mbody">';
  o+='<div class="segs" style="margin:0 4px 14px">'+['For your crew','New','Co-op','Free','Made this week','Remixable'].map(function(t,i){return '<button class="seg" aria-pressed="'+(i===0)+'">'+t+'</button>';}).join('')+'</div>';
  o+='<div class="hero">'+art(FEAT,{tile:false,ttl:false})+'<div class="copy"><div class="tagrow"><span class="stk solid">Featured</span><span class="stk">'+g.genre+'</span><span class="stk">'+g.rating+'% positive</span></div>'+ttl(FEAT,'gtitle')+'<p>'+g.blurb+'</p><div class="seats"><span class="pile">'+av('M','sm')+av('T','sm')+av('S','sm')+'</span><span class="lab">Maya, Theo and Sam wishlisted it</span></div><div class="cta"><button class="primary lg" data-go="game" data-g="'+FEAT+'" data-nav>Get · '+g.price+'</button><button class="ghost lg" data-go="game" data-g="'+FEAT+'" data-nav>'+I.heart+'Wishlist</button></div></div>';
  o+='</div>';
  o+=shelf('Your friends are playing',['moth','kart','garden','neon','maneframe','hex'],{hint:1,link:'See all',go:'library',tagf:function(id){return priceStk(GM[id]);},subf:function(id){var f=friendsOn(id);return av(f,'xs')+P[f][0]+' is playing';}});
  o+=shelf('Made this week, remix allowed',['ruin','pixel','sky','deep','cards'],{badge:'<span class="stk pink">New</span>',link:'See all',go:'library',tagf:function(){return '<span class="stk">'+I.remix.replace('class="i"','class="i" style="width:12px;height:12px"')+'Remix</span>';},subf:function(id){var g=GM[id];return g.genre+' · '+g.price;}});
  o+=shelf('Co-op for five or fewer',['glacier','tide','maneframe','desert','garden','moth'],{link:'See all',go:'library',subf:function(id){var g=GM[id];return g.players+' players · '+g.price;}});
  o+='<div class="oq" style="max-width:640px;margin:16px 4px 40px"><b>Open question</b>Paid games: who sets price, what is the revenue share, and do remixes pay the original creator?</div>';
  return o+'</div>';
}
function library(){
  var o='<div class="mhead"><h1>Library<small>15 games · 4 installed</small></h1><span class="sp"></span><input class="search" style="width:260px" placeholder="Filter your library"></div><div class="mbody">';
  o+='<div class="segs" style="margin:0 4px 4px">'+['All','Installed','Co-op','Party','In Create'].map(function(t,i){return '<button class="seg" aria-pressed="'+(i===0)+'">'+t+'</button>';}).join('')+'</div><div class="lgrid">';
  GAMES.forEach(function(g){o+=gcard(g.id,{tags:priceStk(g),sub:g.genre+' · '+g.players});});
  return o+'</div></div>';
}
function gamePage(){
  var g=GM[S.game],id=g.id;
  var o='<div class="mhead"><button class="icon-btn" data-go="store" title="Back">'+I.back+'</button><h1>'+g.title+'<small>by '+g.by+'</small></h1><span class="sp"></span><button class="ghost">'+I.heart+'Wishlist</button></div><div class="mbody">';
  o+='<div class="ghero">'+art(id,{tile:false,ttl:false})+'<div class="copy"><div class="tagrow" style="display:flex;gap:8px">'+(g.dev?'<span class="stk pink">In development</span>':'<span class="stk solid">'+(g.price==='Free'?'Free to play':g.price)+'</span>')+'<span class="stk">'+g.genre+'</span><span class="stk">'+g.players+' players</span></div>'+ttl(id,'gtitle')+'<div class="sub">'+(g.dev?'Testing with your crew':g.rating+'% positive · '+g.playing+' playing now')+'</div><div class="cta" style="margin-top:18px"><button class="primary lg" data-nav>'+(g.dev?'Playtest build 14':'Get it · '+g.price)+'</button><button class="ghost lg" data-go="party" data-nav>'+I.party+'Play with friends</button></div></div>';
  o+='</div>';
  o+='<div class="tabsline">'+['overview','community','builds','remix'].map(function(t){return '<button data-gtab="'+t+'" aria-current="'+(S.gameTab===t?'page':'false')+'">'+t[0].toUpperCase()+t.slice(1)+'</button>';}).join('')+'</div>';
  if(S.gameTab==='community'){
    o+='<div class="gcols"><div class="panel"><h3># '+id+'-players</h3><p>The game’s player community is a Burrow channel. Plan matches, share clips, find a squad.</p><button class="primary">Open community</button></div></div>';
  } else if(S.gameTab==='remix'){
    o+='<div class="gcols"><div class="panel"><h3>Remix this game</h3><p>Opens a new Create project from this build with its skill agents and engine bridge attached. Credit stays with '+g.by+'.</p><button class="primary" data-go="create">'+I.remix+'Remix in Create</button></div></div>';
  } else if(S.gameTab==='builds'){
    o+='<div class="gcols"><div class="panel"><h3>Build d4afd4e</h3><p>Windows · 85 MB · Burrow Player checks for updates before every launch.</p></div></div>';
  } else {
    o+='<div class="gcols"><div><p style="font-size:15px;line-height:1.7;margin:0 0 12px">'+g.blurb+' Voice, parties and matchmaking come from Burrow.</p>';
    o+='<div class="segs">'+g.tags.map(function(t){return '<span class="pill">'+t+'</span>';}).join('')+'</div>';
    o+='<div class="shots">'+['0 0 160 90','160 0 160 90','80 50 160 90','160 90 160 90'].map(function(vb,i){return art(id,{ttl:false,vb:vb,pos:['0% 0%','100% 0%','50% 50%','100% 100%'][i],tile:false}).replace('class="art scrim"','class="art tile" tabindex="0" data-nav');}).join('')+'</div>';
    if(!g.dev) o+='<div class="score"><span class="num">'+g.rating+'%</span><span>'+STAR5+'<span style="font-size:var(--fs-sm);color:var(--muted)">Very positive · 412 reviews</span></span></div>';
    o+='<div class="review">'+av('T','md',{ring:'on'})+'<div class="txt"><b>Theo</b> <span>· played 6h · friend</span><div>Playing this with four friends yelling over voice is the whole game. In the best way.</div></div></div><div class="review">'+av('R','md')+'<div class="txt"><b>rook_17</b> <span>· played 2h</span><div>Matchmaking found me a full squad in a minute.</div></div></div></div>';
    o+='<div><div class="panel"><div class="price">'+(g.dev?'Build 14':g.price)+'<small>'+(g.dev?'private':'Windows · Mac')+'</small></div><div class="section-label" style="padding-left:0">Friends who own it</div><div style="display:flex;gap:10px;align-items:center"><span class="pile">'+av('M','sm')+av('T','sm')+av('S','sm')+'</span><span style="font-size:var(--fs-sm);color:var(--muted)">3 friends</span></div><p style="margin:14px 0 12px;font-size:var(--fs-sm)">Hosted and distributed by Burrow. Friends, voice and matchmaking built in.</p><button class="ghost" data-gtab="remix">'+I.remix+'Remix this game</button></div>';
    o+='<div class="xpgain">'+I.trophy+'<span><b>12 achievements</b> · Maya has 9, you have 4</span></div></div></div>';
    o+=shelf('More like this',GAMES.filter(function(x){return x.id!==id&&!x.dev;}).slice(0,7).map(function(x){return x.id;}),{});
    o+='<div style="height:30px"></div>';
  }
  return o+'</div>';
}
function gameDetails(){
  var g=GM[S.game];
  return '<div class="dhead"><b>Community</b><span class="pill ok"><i></i>'+g.playing+'</span></div><div class="dbody"><div class="section-label"><span class="livedot"></span>Live now</div>'+
  '<div class="row">'+partyAv('md')+'<span class="txt"><span class="name">rook’s squad <time>3/4</time></span><span class="last">Looking for one more</span></span><button class="ghost">Join</button></div>'+
  '<div class="row"><span class="av party md" style="background:linear-gradient(140deg,#5fe3ff,#b49bff)">'+I.voice+'</span><span class="txt"><span class="name">EU evening <time>2/4</time></span><span class="last">Open to anyone</span></span><button class="ghost">Join</button></div>'+
  '<div class="section-label"># '+g.id+'-players</div><div class="msgs" style="padding:0;overflow:visible">'+msg('I','clip: we finally beat the bridge level').replace('class="msg"','class="msg" style="max-width:100%"')+msg('R','need one more, 9pm EU').replace('class="msg"','class="msg" style="max-width:100%"')+agMsg('bridge','Bridge','Build d4afd4e is live. Patch notes in #updates.').replace('class="msg"','class="msg" style="max-width:100%"')+'</div><button class="ghost" style="margin:14px 2px">Open community</button></div>';
}

/* ---------- phone ---------- */
var TABS=[['play','Play','play','','play-home'],['chat','Chat','chat','3','party'],['discover','Discover','discover','','store'],['create','Create','create','','create'],['me','You','friends','','play-home']];
function pframe(cur,body,title,act,full){
  return '<div class="phone'+(full?' full':'')+'"><div class="status"><span>9:41</span><span class="bat"><i></i></span></div><div class="phead"><h2>'+title+'</h2>'+(act||'<button class="icon-btn">'+I.search+'</button>')+'</div><div class="pbody">'+body+'</div><div class="tabbar glass">'+TABS.map(function(t){return '<button data-go="'+t[4]+'" aria-current="'+(t[0]===cur?'page':'false')+'">'+I[t[2]]+t[1]+(t[3]?'<span class="b">'+t[3]+'</span>':'')+'</button>';}).join('')+'</div></div>';
}
var VB='<div class="pv"><span class="pile">'+'{{P}}'+'</span><span style="flex:1;min-width:0"><b>Friday lions</b><small>3 in voice · voting</small></span>'+EQ+'<span class="mic">'+I.mic+'</span></div>';
function vbar(){return VB.replace('{{P}}',av('J','xs')+av('M','xs')+av('T','xs'));}
function phPlay(){
  return vbar()+'<div class="prow">'+[['M','voice','Lions'],['T','voice','Lions'],['P','on','Moth'],['S','on','Create'],['I','on','Garden'],['R','away','away']].map(function(f){return '<span class="pf">'+av(f[0],'md',{ring:f[1],talk:f[0]==='T'})+P[f[0]][0]+'<small>'+f[2]+'</small></span>';}).join('')+'</div>'+
    '<div class="hero">'+art(PARTY_GAME,{tile:false,ttl:false})+'<div class="copy"><div class="tagrow"><span class="stk pink"><span class="livedot"></span>3 in party</span><span class="stk mint">Free</span></div>'+ttl(PARTY_GAME,'gtitle')+'<button class="primary lg" style="width:100%" data-go="party" data-nav>Join Friday lions</button></div></div>'+
    '<div class="h-sec"><h3>Ranked for three</h3></div><div class="shelf">'+LIB3.slice(0,5).map(function(id,i){return gcard(id,{rank:'#'+(i+1)});}).join('')+'</div>'+
    '<div class="streak" style="margin-top:0">'+I.flame+'<span class="num">3</span><span><b>Night streak</b><span>Play with Maya tonight to keep it</span></span></div>';
}
function phChat(){
  return vbar()+'<div class="segs" style="margin-bottom:10px;flex-wrap:nowrap;overflow:hidden"><button class="seg" aria-pressed="true">All</button><button class="seg">Parties</button><button class="seg">Friends</button><button class="seg">Projects</button></div>'+
    [[partyAv('md'),'Friday lions','Theo: lions at 9? bring a mic','2'],[av('T','md',{ring:'voice'}),'Theo','bring a mic','1'],[av('M','md',{ring:'voice'}),'Maya','kart after?',''],['<span class="av chan md">#</span>','maneframe-players','rook_17: need one more lion',''],['<span class="av agent md" style="--c:#7a85ff">M</span>','Moon Lions · #levels','Atlas: arena 2 ready to playtest',''],[av('P','md',{ring:'on'}),'Priya','lantern run, need a 3rd',''],[agAv('oct','md'),'Guide','Maya’s mic is quiet','']].map(function(c){return '<div class="row" style="padding:10px 4px">'+c[0]+'<span class="txt"><span class="name">'+c[1]+'<time>now</time></span><span class="last">'+c[2]+'</span></span>'+(c[3]?'<span class="badge">'+c[3]+'</span>':'')+'</div>';}).join('');
}
function phDiscover(){
  var g=GM[FEAT];
  return '<div class="segs" style="margin-bottom:12px;flex-wrap:nowrap;overflow:hidden"><button class="seg" aria-pressed="true">For your crew</button><button class="seg">New</button><button class="seg">Free</button><button class="seg">Co-op</button></div>'+
    '<div class="hero">'+art(FEAT,{tile:false,ttl:false})+'<div class="copy"><div class="tagrow"><span class="stk solid">Featured</span></div>'+ttl(FEAT,'gtitle')+'<button class="primary lg" style="width:100%" data-go="game" data-g="'+FEAT+'" data-nav>Get · '+g.price+'</button></div></div>'+
    '<div class="h-sec"><h3>Friends are playing</h3></div><div class="shelf">'+['moth','kart','garden','neon'].map(function(id){var f=friendsOn(id);return gcard(id,{tags:priceStk(GM[id]),sub:av(f,'xs')+P[f][0]});}).join('')+'</div>'+
    '<div class="h-sec" style="margin-top:6px"><h3>New this week</h3></div><div class="pgrid" style="margin-top:14px">'+['pixel','sky','deep','cards'].map(function(id){return gcard(id,{sub:GM[id].price});}).join('')+'</div>';
}
function phCreate(){
  return '<div class="projban" style="margin:0 0 12px;height:110px">'+art('moonlions',{tile:false,ttl:false,tags:'<span class="stk pink">Build 14</span>'})+'</div><div class="segs" style="margin-bottom:12px;flex-wrap:nowrap;overflow:hidden"><button class="seg" aria-pressed="true">Chat</button><button class="seg">Voice</button><button class="seg">Tasks</button><button class="seg">More</button></div>'+
    '<div class="msgs" style="padding:0;overflow:visible">'+msg('S','arena 2 feels too open')+agMsg('atlas','Atlas','Pulled the spawn rings 30% closer and added two choke bridges.')+'<div class="card"><span class="ci">'+I.play+'</span><span class="ct"><b>Build 14 · arena 2</b><span>playable in a party now</span></span></div>'+msg('me','@Echo bridges should creak')+agMsg('echo','Echo','Three creak takes, mapped to landing impulse.')+'</div>';
}
function phone(full){
  var mobile={play:[phPlay,'Tonight','play'],chat:[phChat,'Chat','chat'],discover:[phDiscover,'Discover','discover'],create:[phCreate,'Moon Lions','create']};
  if(full){var k=S.mode==='create'?'create':S.mode==='discover'?'discover':(S.screen==='party'||S.screen==='lfg')?'chat':'play';var m=mobile[k];return pframe(m[2],m[0](),m[1],k==='play'?av('J','sm',{ring:'on'}):null,true);}
  var note='<div class="pnote"><h3>Phone: five tabs</h3><p><b>Play · Chat · Discover · Create · You.</b> Chat is its own tab so parties, DMs, game communities and project channels sit in one list, the same list the desktop rail shows under Chat.</p><p>The live-voice pill pins to the top of every tab while you are in a party. Shelves scroll sideways, covers stay big.</p><p>Create opens today’s mobile Burrow flows unchanged (chat · voice · tasks · meetings · more), wearing the Play skin.</p><div class="oq"><b>Open question</b>Is Create a tab for everyone, or only once you have a project? Most players will never create.</div></div>';
  return '<div class="phone-desk"><div class="pw">'+pframe('play',phPlay(),'Tonight',av('J','sm',{ring:'on'}))+pframe('chat',phChat(),'Chat')+pframe('discover',phDiscover(),'Discover')+pframe('create',phCreate(),'Moon Lions')+note+'</div></div>';
}

/* ---------- render ---------- */
function pcHTML(){
  var sc=[['play-home','Play home'],['party','Party'],['create','Create chat'],['create-tasks','Create tasks'],['store','Store'],['library','Library'],['game','Game page'],['phone','Phone 375']];
  return '<div class="pc glass'+(S.pcMin?' min':'')+'"><div class="h">Prototype · Console Glass v4 <button data-pcmin="1">'+(S.pcMin?'show':'hide')+'</button></div><div class="r">'+sc.map(function(s){return '<button data-go="'+s[0]+'" aria-pressed="'+(S.screen===s[0])+'">'+s[1]+'</button>';}).join('')+'</div><div class="r"><button data-nav-set="switcher" aria-pressed="'+(S.nav==='switcher')+'">Nav A: side rail</button><button data-nav-set="tabs" aria-pressed="'+(S.nav==='tabs')+'">Nav B: console top bar</button></div></div>';
}
var ORBS='<div class="orbs"><i></i><i></i></div>';
function narrow(){return (document.documentElement.clientWidth||window.innerWidth)<760;}
function render(){
  ART_N=0;
  var sc=SCREENS[S.screen], R=document.getElementById('root');
  setTint(S.screen==='game'?GM[S.game].tint:S.mode==='create'?GM.moonlions.tint:S.screen==='store'?GM[FEAT].tint:'#4d8bff');
  if(narrow()){R.innerHTML=ORBS+phone(true);return;}
  if(sc.phone){R.innerHTML=ORBS+phone()+pcHTML();return;}
  var mainH,listH='',detH='',base=S.screen;
  if(S.mode==='play'){var isP=(base==='party'||base==='lfg');mainH=isP?party():playHome();detH=isP?partyDetails():playDetails();}
  else if(S.mode==='create'){listH=createList();mainH=createChat();detH=createDetails();}
  else {mainH=base==='game'?gamePage():base==='library'?library():store();detH=base==='game'?gameDetails():'';}
  var cls='app'+(sc.list?'':' no-list')+(sc.details?'':' no-details')+(S.nav==='tabs'?' tabs':'');
  R.innerHTML=ORBS+'<div class="'+cls+'"><header class="topbar glass">'+topbarHTML()+'</header><aside class="side glass">'+sideHTML()+'</aside><section class="list glass">'+listH+'</section><section class="main">'+mainH+'</section><aside class="details glass">'+detH+'</aside></div>'+pcHTML();
  if(base==='play-home'||base==='store'){var f=document.querySelector('.shelf .tile');if(f){try{f.focus({preventScroll:true});}catch(x){}}}
}
var baseTint='#4d8bff';
function setTint(c){baseTint=c;document.body.style.setProperty('--tint',c);}

/* ---------- console focus: arrows move between tiles, Enter opens ---------- */
function visibleNav(){return Array.prototype.filter.call(document.querySelectorAll('[data-nav]'),function(e){return e.offsetParent!==null&&e.tabIndex>=0;});}
function moveFocus(dir){
  var els=visibleNav(),cur=document.activeElement;
  if(!els.length) return;
  if(!cur||!cur.hasAttribute('data-nav')){var first=els.filter(function(e){return e.classList.contains('tile');})[0]||els[0];focusEl(first);return;}
  var RG='.main,.details,.list,.side,.topbar,.pbody',reg=cur.closest(RG),best=pick(els.filter(function(e){return e.closest(RG)===reg;}),cur,dir)||pick(els,cur,dir);
  if(best) focusEl(best);
}
function pick(els,cur,dir){
  var r=cur.getBoundingClientRect(),cx=r.left+r.width/2,cy=r.top+r.height/2,best=null,bs=1e9;
  els.forEach(function(e){if(e===cur)return;var q=e.getBoundingClientRect(),x=q.left+q.width/2,y=q.top+q.height/2,dx=x-cx,dy=y-cy,pri,sec;
    if(dir==='ArrowRight'){pri=dx;sec=dy;}else if(dir==='ArrowLeft'){pri=-dx;sec=dy;}else if(dir==='ArrowDown'){pri=dy;sec=dx;}else{pri=-dy;sec=dx;}
    if(pri<=8)return;var s=pri+Math.abs(sec)*(dir==='ArrowUp'||dir==='ArrowDown'?0.6:3);if(s<bs){bs=s;best=e;}});
  return best;
}
function focusEl(e){try{e.focus({preventScroll:true});}catch(x){e.focus();}e.scrollIntoView({block:'nearest',inline:'nearest',behavior:'smooth'});}
document.addEventListener('keydown',function(e){
  if(/^Arrow/.test(e.key)){var t=e.target;if(t&&(t.tagName==='INPUT'||t.tagName==='TEXTAREA'))return;e.preventDefault();moveFocus(e.key);}
  else if((e.key==='Enter'||e.key===' ')&&e.target.getAttribute&&e.target.getAttribute('role')==='button'){e.preventDefault();e.target.click();}
});
document.addEventListener('focusin',function(e){
  var t=e.target,id=t.getAttribute&&t.getAttribute('data-game');
  if(!id) return;
  var g=GM[id];document.body.style.setProperty('--tint',g.tint);
  var w=t.closest('.shelfwrap'),fb=w&&w.querySelector('.focusbar');
  if(fb){var k=fb.querySelector('.kbd');fb.innerHTML='<b>'+g.title+'</b><span class="dot"></span>'+g.genre+'<span class="dot"></span>'+g.players+' players<span class="dot"></span>'+(g.dev?'in Create':g.price)+(k?k.outerHTML:'');}
});
document.addEventListener('focusout',function(e){if(e.target.getAttribute&&e.target.getAttribute('data-game'))document.body.style.setProperty('--tint',baseTint);});
document.addEventListener('mouseover',function(e){var t=e.target.closest&&e.target.closest('[data-game]');if(t&&t!==document.activeElement&&t.classList.contains('tile'))t.focus({preventScroll:true});});
document.addEventListener('click',function(e){
  var t=e.target.closest('[data-game],[data-go],[data-mode],[data-nav-set],[data-vote],[data-gtab],[data-pcmin]');
  if(!t) return;
  if(t.dataset.vote&&!e.target.closest('[data-game]')){S.vote=t.dataset.vote;render();return;}
  if(t.dataset.game){S.game=t.dataset.game;S.gameTab='overview';go('game');}
  else if(t.dataset.go){if(t.dataset.g)S.game=t.dataset.g;go(t.dataset.go);}
  else if(t.dataset.mode){go({play:'play-home',create:'create',discover:'store'}[t.dataset.mode]);}
  else if(t.dataset.navSet){S.nav=t.dataset.navSet;sync();}
  else if(t.dataset.vote){S.vote=t.dataset.vote;render();}
  else if(t.dataset.gtab){S.gameTab=t.dataset.gtab;S.screen='game';S.mode='discover';render();}
  else if(t.dataset.pcmin){S.pcMin=!S.pcMin;sync();}
});
var wasNarrow=null;window.addEventListener('resize',function(){var n=narrow();if(n!==wasNarrow){wasNarrow=n;render();}});
readHash();wasNarrow=narrow();
render();
})();
