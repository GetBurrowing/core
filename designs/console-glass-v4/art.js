/* ============================================================
   GAME DATA: the one array to replace when real screens arrive.
   Each entry drives every tile, hero, shelf, store row and game page.
   Swap-in path: drop an image named <id>.png|jpg|webp into v4/screens/
   and rebuild; build.py inlines it as GAME_IMG[id] and cover() uses it
   instead of the generated SVG scene. Or set `img` on an entry directly.
   Fields: id, title, genre, players, price, by, blurb, rating (% positive),
   playing (now), tint (background tint on focus), tf (title treatment:
   heavy|wide|italic|outline|serif|round|pixel), tags, dev (in Create, not shipped).
   ============================================================ */
var GAMES=[
 {id:'maneframe',title:'Mane Frame: Defenders',genre:'Co-op mech',players:'5',price:'Free',by:'Lionworks',tint:'#6d2fd0',tf:'heavy',rating:94,playing:'1.2k',tags:['Co-op','5 players','Controller','Voice','Early access'],blurb:'Five players, five lions. Pilot your lion through a wrecked city, then combine into the titan where every player drives one limb.'},
 {id:'moth',title:'Moth Lantern',genre:'Co-op puzzle',players:'2–4',price:'$6',by:'Paper Owl',tint:'#c2561a',tf:'serif',rating:91,playing:'640',tags:['Co-op','Puzzle','Story'],blurb:'Carry the last lantern through a city of moths. The light is shared, and so is the blame.'},
 {id:'kart',title:'Burrow Kart',genre:'Party racer',players:'2–8',price:'$4',by:'Pit Crew',tint:'#2fbf5a',tf:'italic',rating:88,playing:'2.4k',tags:['Party','Racing','Couch'],blurb:'Eight karts, one ramp, zero brakes. Items are made by the players who lost last round.'},
 {id:'tide',title:'Low Tide',genre:'Survival',players:'1–4',price:'$9',by:'Saltworks',tint:'#1a7fa8',tf:'wide',rating:86,playing:'820',tags:['Survival','Crafting','Co-op'],blurb:'The sea goes out a mile every night. Build what you can before it comes back.'},
 {id:'hex',title:'Hexfall',genre:'Strategy',players:'2',price:'Free',by:'Sam & co',tint:'#7b3fd6',tf:'heavy',rating:83,playing:'310',tags:['Strategy','Versus','Turn-based'],blurb:'A two-player tile war on a board that collapses one hex per turn.'},
 {id:'ruin',title:'Ruin Runners',genre:'Roguelike',players:'1–3',price:'$5',by:'Dust Bunny',tint:'#e2463a',tf:'outline',rating:90,playing:'1.1k',tags:['Roguelike','Action','Co-op'],blurb:'Sprint through a temple that rebuilds itself every run. Grab the relic, outrun the sunset.'},
 {id:'moonlions',title:'Moon Lions',genre:'Arena brawler',players:'2–6',price:'In development',by:'your crew',tint:'#4a55c8',tf:'wide',rating:0,playing:'4 testers',dev:true,tags:['Brawler','Arena','Godot'],blurb:'Lions on the moon, low gravity, one arena. Your crew is building it in Create.'},
 {id:'glacier',title:'Frostbite Couriers',genre:'Co-op delivery',players:'1–4',price:'$7',by:'Snowline',tint:'#4f86c6',tf:'round',rating:92,playing:'930',tags:['Co-op','Chaos','Couch'],blurb:'Sled parcels across a glacier that is actively falling apart. Tips are mostly for survival.'},
 {id:'neon',title:'Neon Drift Club',genre:'Rhythm racer',players:'1–8',price:'$8',by:'Afterglow',tint:'#ff2fa0',tf:'italic',rating:89,playing:'1.6k',tags:['Racing','Rhythm','Online'],blurb:'Drift on the beat. Every corner is a note, every lap is a track you can remix.'},
 {id:'garden',title:'Mossling Garden',genre:'Cozy farming',players:'1–4',price:'$12',by:'Fernhouse',tint:'#3e9a55',tf:'round',rating:95,playing:'3.1k',tags:['Cozy','Farming','Co-op'],blurb:'Grow a garden with tiny moss creatures who have strong opinions about mushrooms.'},
 {id:'deep',title:'Abyss Choir',genre:'Horror · explore',players:'1–3',price:'$10',by:'Undertow',tint:'#0f6c7c',tf:'serif',rating:87,playing:'540',tags:['Horror','Exploration','Co-op'],blurb:'Dive past the light. Something down there sings back when you use voice chat.'},
 {id:'sky',title:'Kite Kingdoms',genre:'Flying adventure',players:'1–4',price:'Free',by:'Updraft',tint:'#8e7bff',tf:'round',rating:90,playing:'2.0k',tags:['Adventure','Flying','Free'],blurb:'Ride the wind between floating islands and claim them with the kite you built.'},
 {id:'pixel',title:'Bit Bandits',genre:'Heist platformer',players:'1–4',price:'$3',by:'8-Bit Den',tint:'#5a3fd0',tf:'pixel',rating:85,playing:'720',tags:['Platformer','Heist','Retro'],blurb:'A pixel crew, a city of vaults, and a getaway plan that always goes wrong.'},
 {id:'desert',title:'Sandglass Sailors',genre:'Open-world sailing',players:'1–6',price:'$14',by:'Dune Co',tint:'#e08a3a',tf:'wide',rating:93,playing:'1.4k',tags:['Open world','Sailing','Co-op'],blurb:'Sail a sand-ship under two suns. Your crew trims the sails, you argue about the map.'},
 {id:'cards',title:'Hollow Hand',genre:'Deckbuilder',players:'1–2',price:'$6',by:'Candlelight',tint:'#1f7a55',tf:'serif',rating:91,playing:'880',tags:['Cards','Strategy','Versus'],blurb:'Build a deck from cards that remember who played them last.'}
];
var GM={};GAMES.forEach(function(g){GM[g.id]=g;});
var GAME_IMG={/*{{GAME_IMG}}*/};

/* ---------- new scenes (320x180) ---------- */
function stars(n,seed,ymax,col){var o='',s=seed;for(var i=0;i<n;i++){s=(s*9301+49297)%233280;var x=s/233280*320;s=(s*9301+49297)%233280;var y=s/233280*ymax;o+='<circle cx="'+x.toFixed(1)+'" cy="'+y.toFixed(1)+'" r="'+(i%3?0.9:1.5)+'"/>';}return '<g fill="'+(col||'#fff')+'" opacity=".8">'+o+'</g>';}
function mane(cx,cy,r1,r2,n){var p=[];for(var i=0;i<n*2;i++){var a=Math.PI*i/n,r=i%2?r2:r1;p.push((cx+Math.cos(a)*r).toFixed(1)+','+(cy+Math.sin(a)*r).toFixed(1));}return p.join(' ');}
var SC_NEW={
 moonlions:function(id){
  return ['<linearGradient id="'+id('a')+'" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#070d33"/><stop offset=".6" stop-color="#24317a"/><stop offset="1" stop-color="#6b4aa8"/></linearGradient><radialGradient id="'+id('g')+'"><stop offset="0" stop-color="#fff" stop-opacity=".35"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>',
  '<rect width="320" height="180" fill="url(#'+id('a')+')"/>'+stars(40,7,120)+'<circle cx="214" cy="78" r="88" fill="url(#'+id('g')+')"/><circle cx="214" cy="78" r="52" fill="#f1ecdb"/><g fill="#d6cfb8"><circle cx="192" cy="60" r="9"/><circle cx="236" cy="96" r="12"/><circle cx="240" cy="56" r="5"/><circle cx="196" cy="104" r="6"/></g>'+
  '<path d="M0 180V140q40-18 90-10t80-12l40 6 30-14 40 8 40-4v66z" fill="#0b1032"/><path d="M150 180v-50l26-14h80l40 18v46z" fill="#070a24"/>'+
  '<g fill="#070a24"><polygon points="'+mane(214,84,34,24,14)+'"/><ellipse cx="226" cy="124" rx="38" ry="18"/><rect x="196" y="126" width="9" height="22" rx="3"/><rect x="240" y="126" width="9" height="22" rx="3"/><path d="M262 118q22-6 26-24q-2 18-20 30z"/></g><circle cx="207" cy="84" r="2.6" fill="#ffb03a"/><circle cx="222" cy="84" r="2.6" fill="#ffb03a"/>'];
 },
 glacier:function(id){
  return ['<linearGradient id="'+id('a')+'" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1d3f7a"/><stop offset=".55" stop-color="#5d9bd6"/><stop offset="1" stop-color="#cfeeff"/></linearGradient><linearGradient id="'+id('u')+'" x1="0" x2="1"><stop offset="0" stop-color="#5dffc4"/><stop offset=".5" stop-color="#4ad7ff"/><stop offset="1" stop-color="#b47bff"/></linearGradient>',
  '<rect width="320" height="180" fill="url(#'+id('a')+')"/><path d="M0 40q60-30 130 0t120-6 70 10v26q-40-16-80-4t-110 2T0 66z" fill="url(#'+id('u')+')" opacity=".55"/>'+stars(18,3,50)+
  '<path d="M0 120 50 70l30 26 40-46 50 60 40-40 50 44 30-24 30 30v60H0z" fill="#9cc6ea"/><path d="M50 70l14 13-8 2-6 8-6-6-10 2zM120 50l18 21-10-2-8 10-6-9-12 4zM210 64l15 15-9 0-6 7-5-7-10 1z" fill="#fff"/>'+
  '<path d="M0 140q80-20 160-6t160-10v56H0z" fill="#f2faff"/><path d="M0 160q90-14 190-2t130-6v28H0z" fill="#d7ebf8"/>'+
  '<g stroke="#1e2d4f" stroke-width="2.5"><path d="M118 150h70q8 0 8-8" fill="none" stroke-linecap="round"/><rect x="128" y="120" width="24" height="24" rx="3" fill="#ff6a3d"/><rect x="152" y="126" width="22" height="18" rx="3" fill="#ffc247"/><rect x="138" y="106" width="16" height="14" rx="2" fill="#fff"/></g><path d="M140 120h12M163 126v18" stroke="#1e2d4f" stroke-width="2"/>'+
  '<g stroke="#1e2d4f" stroke-width="2.5"><circle cx="186" cy="116" r="8" fill="#ffe0c7"/><path d="M178 122h16l-2 20h-12z" fill="#2f6fe0"/><path d="M180 122l-14 4" stroke="#ff3b4e" stroke-width="5" stroke-linecap="round"/></g>'+
  '<g fill="#fff">'+'<circle cx="30" cy="100" r="1.6"/><circle cx="80" cy="128" r="1.2"/><circle cx="250" cy="110" r="1.8"/><circle cx="290" cy="90" r="1.2"/><circle cx="220" cy="140" r="1.4"/></g>'];
 },
 neon:function(id){
  var g='';for(var i=0;i<=12;i++){var x=-120+i*46.6;g+='<path d="M160 112L'+x.toFixed(1)+' 180"/>';}
  [116,122,130,141,156,176].forEach(function(y){g+='<path d="M0 '+y+'H320"/>';});
  return ['<linearGradient id="'+id('a')+'" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0e0224"/><stop offset=".6" stop-color="#4a0c6e"/><stop offset="1" stop-color="#ff3f9e"/></linearGradient><linearGradient id="'+id('s')+'" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffec6b"/><stop offset="1" stop-color="#ff3d8b"/></linearGradient><clipPath id="'+id('c')+'"><circle cx="160" cy="80" r="50"/></clipPath>',
  '<rect width="320" height="112" fill="url(#'+id('a')+')"/>'+stars(30,11,70)+'<g clip-path="url(#'+id('c')+')"><rect x="100" y="28" width="120" height="90" fill="url(#'+id('s')+')"/><g fill="#5a0e72"><rect x="100" y="84" width="120" height="3"/><rect x="100" y="93" width="120" height="4"/><rect x="100" y="102" width="120" height="6"/></g></g>'+
  '<path d="M0 112l40-26 30 14 34-22 30 34zM186 112l40-30 30 18 30-24 34 36z" fill="#2a0545"/><rect y="112" width="320" height="68" fill="#10021e"/><g stroke="#34f0ff" stroke-width="1.4" opacity=".85">'+g+'</g>'+
  '<g><path d="M126 176v-18q0-10 10-14l8-8h32l8 8q10 4 10 14v18z" fill="#06000f" stroke="#ff4fd8" stroke-width="2"/><rect x="132" y="156" width="16" height="5" rx="2" fill="#ff2a6d"/><rect x="172" y="156" width="16" height="5" rx="2" fill="#ff2a6d"/><path d="M148 140h24l5 8h-34z" fill="#34f0ff" opacity=".5"/></g>'];
 },
 garden:function(id){
  return ['<linearGradient id="'+id('a')+'" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffe9b0"/><stop offset=".5" stop-color="#bfeaa0"/><stop offset="1" stop-color="#6fc879"/></linearGradient>',
  '<rect width="320" height="180" fill="url(#'+id('a')+')"/><circle cx="252" cy="40" r="22" fill="#fff6c8"/><path d="M0 110q70-40 150-10t170-14v94H0z" fill="#7fcf6f"/><path d="M0 140q90-30 180-6t140-12v58H0z" fill="#3e9a55"/>'+
  '<g><rect x="54" y="88" width="16" height="50" rx="7" fill="#f6e9d0"/><path d="M28 92q34-46 68 0z" fill="#e8483f"/><g fill="#fff"><circle cx="48" cy="78" r="5"/><circle cx="66" cy="70" r="4"/><circle cx="80" cy="84" r="3.5"/></g></g>'+
  '<g><rect x="240" y="116" width="10" height="28" rx="4" fill="#f6e9d0"/><path d="M226 120q19-26 38 0z" fill="#ff9a3c"/><circle cx="240" cy="112" r="3" fill="#fff"/></g>'+
  '<g stroke="#1f4a2a" stroke-width="3"><ellipse cx="160" cy="138" rx="26" ry="22" fill="#8fe36b"/><path d="M160 116q-4-14 6-20M166 96q10-2 14 6-8 4-14-6z" fill="#5bc04a"/></g><circle cx="151" cy="134" r="5" fill="#fff"/><circle cx="169" cy="134" r="5" fill="#fff"/><circle cx="152" cy="135" r="2.4" fill="#1f2a20"/><circle cx="170" cy="135" r="2.4" fill="#1f2a20"/><path d="M155 146q5 4 10 0" stroke="#1f4a2a" stroke-width="2.4" fill="none" stroke-linecap="round"/>'+
  '<g fill="#fff27a"><circle cx="110" cy="70" r="2.4"/><circle cx="200" cy="80" r="2"/><circle cx="290" cy="96" r="2.6"/><circle cx="20" cy="60" r="2"/></g><g fill="#ff7ab8"><circle cx="110" cy="156" r="4"/><circle cx="210" cy="160" r="3.5"/><circle cx="290" cy="150" r="4"/></g>'];
 },
 deep:function(id){
  return ['<radialGradient id="'+id('a')+'" cx=".5" cy="0" r="1.1"><stop offset="0" stop-color="#1b7a8a"/><stop offset=".55" stop-color="#062a33"/><stop offset="1" stop-color="#020b10"/></radialGradient><radialGradient id="'+id('l')+'"><stop offset="0" stop-color="#e9fff8"/><stop offset=".3" stop-color="#7affd9" stop-opacity=".7"/><stop offset="1" stop-color="#7affd9" stop-opacity="0"/></radialGradient>',
  '<rect width="320" height="180" fill="url(#'+id('a')+')"/><g fill="#bff" opacity=".07"><path d="M90 0h30l-60 180H20z"/><path d="M170 0h20l20 180h-50z"/><path d="M250 0h40l-20 180h-30z"/></g>'+
  '<g fill="none" stroke="#9ff3e6" stroke-opacity=".5"><circle cx="60" cy="60" r="3"/><circle cx="66" cy="44" r="2"/><circle cx="58" cy="30" r="1.4"/><circle cx="280" cy="120" r="3"/><circle cx="274" cy="100" r="2"/></g>'+
  '<circle cx="132" cy="70" r="40" fill="url(#'+id('l')+')"/><path d="M132 70q30-30 64 4" stroke="#0a3a40" stroke-width="3" fill="none"/>'+
  '<path d="M190 96q40-40 100-10 18 10 30 30-30 24-70 24-40 0-60-20z" fill="#041a20" stroke="#0e4c55" stroke-width="2"/><path d="M196 100l8 10 6-12 7 14 7-14 7 14 6-12 8 12" stroke="#e6fff8" stroke-width="2" fill="none" stroke-linejoin="round"/><circle cx="246" cy="92" r="6" fill="#d9fff4"/><circle cx="247" cy="92" r="2.6" fill="#020b10"/>'+
  '<g fill="#020b10"><path d="M0 180v-24q40-10 80 0t80-4 80 6 80-6v28z"/></g><g stroke="#0d4a3a" stroke-width="4" fill="none" stroke-linecap="round"><path d="M20 172q-8-20 4-40"/><path d="M36 174q8-26-4-48"/><path d="M300 176q-10-18 2-34"/></g>'+
  '<g><circle cx="58" cy="118" r="5" fill="#0b2228" stroke="#2fd0b8" stroke-width="1.5"/><path d="M54 123l-6 14M62 123l8 12M58 123v8" stroke="#0b2228" stroke-width="4" stroke-linecap="round"/><path d="M62 116l40-16v10z" fill="#c8fff2" opacity=".25"/></g>'];
 },
 sky:function(id){
  function isl(x,y,s,c){return '<g transform="translate('+x+' '+y+') scale('+s+')"><path d="M-40 0q40-14 80 0l-18 30-14 26-10-20-14 6z" fill="#7a5a8a"/><path d="M-42 0q42-16 84 0q-42 10-84 0z" fill="#5fc17a"/><rect x="18" y="4" width="6" height="'+(c?60:40)+'" fill="#bfe8ff" opacity=".8"/></g>';}
  return ['<linearGradient id="'+id('a')+'" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8ec5ff"/><stop offset=".55" stop-color="#c8b6ff"/><stop offset="1" stop-color="#ffd6c2"/></linearGradient>',
  '<rect width="320" height="180" fill="url(#'+id('a')+')"/><g fill="#fff" opacity=".85"><ellipse cx="60" cy="150" rx="70" ry="18"/><ellipse cx="270" cy="160" rx="80" ry="20"/><ellipse cx="200" cy="40" rx="40" ry="10"/></g>'+
  isl(90,78,1.1,1)+isl(240,96,.8,0)+isl(176,140,.55,0)+'<g transform="translate(90 72)"><rect x="-10" y="-22" width="20" height="22" fill="#f3e8ff"/><path d="M-13 -22l13-14 13 14z" fill="#ff6b8b"/><rect x="-3" y="-10" width="6" height="10" fill="#7a5a8a"/></g>'+
  '<g stroke="#2a1f4a" stroke-width="2"><path d="M222 20l14 16-14 20-14-20z" fill="#ffd23f"/><path d="M222 56q-6 14 4 24t-2 26" fill="none"/><path d="M150 52l9 11-9 13-9-13z" fill="#ff4fa3"/><path d="M150 76q6 10-2 18" fill="none"/></g><g fill="#2a1f4a"><path d="M224 82l6-3 0 6zM226 98l-6-3 0 6z"/></g>'];
 },
 pixel:function(id){
  var o='',s=5,b=[[0,70,26],[30,96,22],[56,60,30],[90,84,24],[118,50,34],[208,72,28],[240,92,22],[266,56,30],[300,80,20]];
  b.forEach(function(r){o+='<rect x="'+r[0]+'" y="'+r[1]+'" width="'+r[2]+'" height="'+(180-r[1])+'" fill="#120d2e"/>';for(var yy=r[1]+6;yy<170;yy+=10)for(var xx=r[0]+4;xx<r[0]+r[2]-4;xx+=8){s=(s*9301+49297)%233280;if(s/233280>.55)o+='<rect x="'+xx+'" y="'+yy+'" width="4" height="5" fill="#ffd23f"/>';}});
  var map=['..KKKK..','.KKKKKK.','.KWKKWK.','.KKKKKK.','..RRRR..','.RRRRRRY','RRRRRRYY','.RR..RYY','.KK..KK.'],px='',C={K:'#1a1033',W:'#fff',R:'#ff3b4e',Y:'#ffd23f'};
  map.forEach(function(row,y){for(var x=0;x<row.length;x++){var c=row.charAt(x);if(c!=='.')px+='<rect x="'+(146+x*4)+'" y="'+(102+y*4)+'" width="4" height="4" fill="'+C[c]+'"/>';}});
  return ['<linearGradient id="'+id('a')+'" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1b1446"/><stop offset="1" stop-color="#5a3fd0"/></linearGradient>',
  '<g shape-rendering="crispEdges"><rect width="320" height="180" fill="url(#'+id('a')+')"/><g fill="#fff">'+'<rect x="40" y="20" width="2" height="2"/><rect x="100" y="34" width="2" height="2"/><rect x="200" y="14" width="2" height="2"/><rect x="290" y="30" width="2" height="2"/><rect x="170" y="44" width="2" height="2"/></g>'+
  '<g fill="#fff6c8"><rect x="236" y="18" width="24" height="24"/><rect x="232" y="22" width="32" height="16"/></g><rect x="244" y="24" width="6" height="6" fill="#e6dca8"/>'+
  '<path d="M180 0l40 0-60 140h-20z" fill="#fff" opacity=".08"/>'+o+'<rect x="140" y="138" width="60" height="42" fill="#1a1033"/><rect x="134" y="136" width="72" height="4" fill="#3a2a7a"/>'+px+'</g>'];
 },
 desert:function(id){
  return ['<linearGradient id="'+id('a')+'" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ff8a5b"/><stop offset=".6" stop-color="#ffc276"/><stop offset="1" stop-color="#ffe3a8"/></linearGradient>',
  '<rect width="320" height="180" fill="url(#'+id('a')+')"/><circle cx="90" cy="54" r="26" fill="#fff4c9"/><circle cx="136" cy="74" r="12" fill="#ffd9a0"/>'+
  '<path d="M0 110q60-24 120-6t110-10 90 8v78H0z" fill="#e9a24e"/><path d="M0 134q80-26 170-4t150-6v56H0z" fill="#c97a34"/>'+
  '<g><path d="M178 132h86l-12 14h-64z" fill="#4a2a1a"/><path d="M220 130V62" stroke="#4a2a1a" stroke-width="3"/><path d="M222 64l40 60h-40z" fill="#f5ecd8"/><path d="M218 70l-32 54h32z" fill="#fff8ea"/><path d="M222 92l22 10v8l-22-10z" fill="#d2453a"/><path d="M188 146l-6 10M256 146l6 10" stroke="#4a2a1a" stroke-width="3"/></g>'+
  '<path d="M0 160q100-18 200 0t120-4v24H0z" fill="#8f4f22"/><g fill="#fff3d6" opacity=".7"><circle cx="40" cy="120" r="1.2"/><circle cx="150" cy="114" r="1"/><circle cx="290" cy="124" r="1.4"/></g>'];
 },
 cards:function(id){
  function card(rot,x,sig,col){return '<g transform="translate('+x+' 96) rotate('+rot+')"><rect x="-30" y="-44" width="60" height="88" rx="7" fill="#f3ead2" stroke="#d4a64a" stroke-width="2.5"/><rect x="-24" y="-38" width="48" height="76" rx="4" fill="none" stroke="#d4a64a" stroke-width="1"/>'+sig.replace(/CC/g,col)+'</g>';}
  var eye='<path d="M-16 0q16-14 32 0-16 14-32 0z" fill="none" stroke="CC" stroke-width="2.5"/><circle r="5" fill="CC"/>';
  var moon='<path d="M6-14a14 14 0 1 0 0 28 11 11 0 1 1 0-28z" fill="CC"/>';
  var star='<path d="M0-16l4 11h12l-10 7 4 12-10-7-10 7 4-12-10-7h12z" fill="CC"/>';
  return ['<radialGradient id="'+id('a')+'" cx=".5" cy=".45" r=".75"><stop offset="0" stop-color="#2a7a5a"/><stop offset="1" stop-color="#05140e"/></radialGradient><radialGradient id="'+id('c')+'"><stop offset="0" stop-color="#ffd27a" stop-opacity=".55"/><stop offset="1" stop-color="#ffd27a" stop-opacity="0"/></radialGradient>',
  '<rect width="320" height="180" fill="url(#'+id('a')+')"/><circle cx="270" cy="34" r="60" fill="url(#'+id('c')+')"/><g><rect x="264" y="30" width="10" height="34" rx="2" fill="#f3ead2"/><path d="M269 18q6 8 0 12-6-4 0-12z" fill="#ffcf5a"/></g>'+
  '<g stroke="#d4a64a" stroke-opacity=".35" fill="none"><circle cx="160" cy="96" r="70"/><circle cx="160" cy="96" r="78" stroke-dasharray="2 6"/></g>'+
  card(-16,118,moon,'#1f5a8a')+card(14,202,star,'#b8333a')+card(0,160,eye,'#1f4a3a')];
 }
};
/* ---------- the original six scenes (v3), re-keyed ---------- */
var SC_OLD={
 maneframe:function(id){var d='',b='';
    d='<linearGradient id="'+id('a')+'" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2b1b6e"/><stop offset=".55" stop-color="#6d2fd0"/><stop offset="1" stop-color="#ff5a7a"/></linearGradient><radialGradient id="'+id('m')+'" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#fff3c4"/><stop offset="1" stop-color="#ffcf4a"/></radialGradient>';
    b='<rect width="320" height="180" fill="url(#'+id('a')+')"/><circle cx="236" cy="52" r="30" fill="url(#'+id('m')+')" opacity=".95"/>'+
      '<g fill="#fff" opacity=".7"><circle cx="40" cy="22" r="1.4"/><circle cx="90" cy="40" r="1"/><circle cx="150" cy="18" r="1.6"/><circle cx="290" cy="110" r="1.2"/><circle cx="20" cy="70" r="1"/></g>'+
      '<path d="M0 150V118h18v-22h14v30h12V92h20v34h10v-44h24v40h12v-26h16v58h14V104h22v22h14V86h18v40h10v-28h20v52h12v-36h18v34h14V110h24v70H0z" fill="#1a0f3d"/>'+
      '<g transform="translate(0 -20)"><g stroke="#120a2b" stroke-width="3"><circle cx="160" cy="98" r="17" fill="#2a2a33"/><circle cx="124" cy="122" r="12" fill="#ff3b4e"/><circle cx="196" cy="122" r="12" fill="#22d36b"/><circle cx="138" cy="148" r="11" fill="#2f7dff"/><circle cx="182" cy="148" r="11" fill="#ffd23f"/></g>'+
      '<g fill="#120a2b"><path d="M148 84l4-10 5 8zM172 84l-4-10-5 8z"/></g><circle cx="154" cy="96" r="2.4" fill="#ffd23f"/><circle cx="166" cy="96" r="2.4" fill="#ffd23f"/></g>';
  return [d,b];},
 moth:function(id){var d='',b='';
    d='<radialGradient id="'+id('a')+'" cx=".35" cy=".45" r=".8"><stop offset="0" stop-color="#ffd27a"/><stop offset=".35" stop-color="#c2561a"/><stop offset="1" stop-color="#1c0b18"/></radialGradient>';
    b='<rect width="320" height="180" fill="url(#'+id('a')+')"/><circle cx="112" cy="82" r="44" fill="#fff1c2" opacity=".25"/>'+
      '<g stroke="#2a1208" stroke-width="3"><path d="M112 46v10" /><rect x="96" y="56" width="32" height="44" rx="8" fill="#ffe8a3"/><path d="M92 56h40M92 100h40"/></g><circle cx="112" cy="78" r="8" fill="#ff9a3c"/>'+
      '<g fill="#3b1a2e" stroke="#ffe8a3" stroke-width="1.5"><path d="M200 60c10-14 26-10 24 2-8 2-14 4-24-2zM200 60c-6-16 6-26 14-18-2 8-6 12-14 18z"/><path d="M250 98c8-11 21-8 19 2-6 1-11 3-19-2zM250 98c-5-13 5-21 11-14-2 6-5 9-11 14z"/><path d="M168 30c6-8 15-6 14 1-4 1-8 2-14-1zM168 30c-3-9 3-15 8-10-1 4-3 7-8 10z"/></g>'+
      '<path d="M0 180v-30c40-14 80 6 120-4s70-20 110-8 60 14 90 4v38z" fill="#160812"/>';
  return [d,b];},
 kart:function(id){var d='',b='';
    d='<linearGradient id="'+id('a')+'" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#36e0ff"/><stop offset=".55" stop-color="#7cf0a8"/></linearGradient>';
    b='<rect width="320" height="180" fill="url(#'+id('a')+')"/><path d="M0 92q80-26 160-6t160-8v102H0z" fill="#2fbf5a"/>'+
      '<path d="M120 180 150 88h20l30 92z" fill="#3a3550"/><path d="M158 96h4l3 18h-10zM157 124h6l3 24h-12zM155 160h10l3 20h-16z" fill="#ffd23f"/>'+
      '<g stroke="#1a1430" stroke-width="3"><path d="M176 132h50l10 18h-72z" fill="#ff4fa3"/><rect x="190" y="118" width="22" height="16" rx="5" fill="#ffd23f"/><circle cx="182" cy="152" r="9" fill="#1a1430"/><circle cx="228" cy="152" r="9" fill="#1a1430"/></g>'+
      '<g fill="#fff" opacity=".9"><path d="M30 40q8-10 18 0 10-6 16 4H24q0-6 6-4z"/><path d="M240 30q8-10 18 0 10-6 16 4h-40q0-6 6-4z"/></g>'+
      '<g fill="#1a1430"><rect x="20" y="96" width="6" height="16"/><rect x="34" y="96" width="6" height="16"/></g><path d="M20 96h20v6H20z" fill="#fff"/>';
  return [d,b];},
 tide:function(id){var d='',b='';
    d='<linearGradient id="'+id('a')+'" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ff9f6b"/><stop offset=".5" stop-color="#ff5f8f"/><stop offset=".51" stop-color="#1a7fa8"/><stop offset="1" stop-color="#0a2e4a"/></linearGradient>';
    b='<rect width="320" height="180" fill="url(#'+id('a')+')"/><circle cx="160" cy="90" r="34" fill="#ffd27a"/><rect y="90" width="320" height="90" fill="#16739a"/>'+
      '<g stroke="#bff4ff" stroke-width="3" fill="none" stroke-linecap="round" opacity=".8"><path d="M20 112q14-8 28 0t28 0"/><path d="M200 128q14-8 28 0t28 0"/><path d="M90 150q14-8 28 0t28 0"/></g>'+
      '<path d="M210 96q20-20 50-6l10 6z" fill="#0d3b2c"/><path d="M238 92c0-20 4-34 2-48M240 46c-12-4-22 0-28 6M240 46c10-6 22-4 28 2M240 46c-4-10-14-14-22-12" stroke="#0d3b2c" stroke-width="4" fill="none" stroke-linecap="round"/>'+
      '<path d="M70 104l14-18 14 18z" fill="#fff"/><path d="M84 86v20" stroke="#3a2a20" stroke-width="2"/><path d="M62 106h44l-6 8H68z" fill="#7a3e1c"/>';
  return [d,b];},
 hex:function(id){var d='',b='';
    d='<linearGradient id="'+id('a')+'" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#b36bff"/><stop offset="1" stop-color="#2a0f5c"/></linearGradient>';
    var hx='';for(var r=0;r<5;r++)for(var c=0;c<9;c++){var x=c*40+(r%2?20:0)-10,y=r*34+10,f=['#ffd23f','#3ee0ff','#ff4fa3','#ffffff'][(r*3+c)%11===0?0:(r+c)%7===0?1:(r*c)%13===5?2:3];hx+='<path d="M'+x+' '+(y-18)+'l17 10v20l-17 10-17-10v-20z" fill="'+(f==='#ffffff'?'none':f)+'" stroke="#e8d6ff" stroke-opacity=".35" stroke-width="2"'+(f==='#ffffff'?'':' fill-opacity=".9"')+'/>';}
    b='<rect width="320" height="180" fill="url(#'+id('a')+')"/>'+hx+'<path d="M200 40l10 26 28 2-22 17 8 27-24-16-24 16 8-27-22-17 28-2z" fill="#ffd23f" stroke="#2a0f5c" stroke-width="3"/>';
  return [d,b];},
 ruin:function(id){var d='',b='';
    d='<linearGradient id="'+id('a')+'" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffb347"/><stop offset="1" stop-color="#e2463a"/></linearGradient>';
    b='<rect width="320" height="180" fill="url(#'+id('a')+')"/><circle cx="70" cy="60" r="26" fill="#fff0b8"/>'+
      '<g fill="#5a1d1a"><rect x="150" y="60" width="18" height="90"/><rect x="190" y="80" width="18" height="70"/><rect x="230" y="50" width="18" height="100"/><path d="M140 52h120v12H140z"/><path d="M262 104l30-20v66h-30z"/></g>'+
      '<path d="M0 150h320v30H0z" fill="#3a0f12"/>'+
      '<g stroke="#120406" stroke-width="3" stroke-linecap="round" fill="none"><path d="M100 98l-6 22-14 12M94 120l14 10 4 16M98 104l14 4 10-6M98 104l-14 4-6 8"/></g><circle cx="102" cy="90" r="7" fill="#120406"/>'+
      '<path d="M120 112h22M118 120h16" stroke="#fff0b8" stroke-width="3" stroke-linecap="round"/>';
  return [d,b];}
};
/* cover(id,{vb,pos}) -> art markup. Uses a real screenshot when GAME_IMG/img has one, else the SVG scene. */
var ART_N=0;
function cover(k,o){
  o=o||{};var g=GM[k],src=(g&&g.img)||GAME_IMG[k];
  if(src) return '<img class="cv" src="'+src+'" alt=""'+(o.pos?' style="object-position:'+o.pos+';transform:scale(1.7)"':'')+'>';
  var n=++ART_N,id=function(s){return 'g'+n+s;},f=SC_NEW[k]||SC_OLD[k],r=f(id);
  return '<svg class="cv" viewBox="'+(o.vb||'0 0 320 180')+'" preserveAspectRatio="xMidYMid slice" aria-hidden="true"><defs>'+r[0]+'</defs>'+r[1]+'</svg>';
}
