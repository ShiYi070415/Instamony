/*
 * JavaScript injected into the Instagram WebView.
 *
 * The native shell never reads the account token. It receives only ordinary
 * page data (posts, URLs and the signed-in state) through window.ogNative.
 */
const PROXY: string = 'ogNative';
/**
 * Instagram 网页端的 App ID。
 *
 * 它出现在网页自己的请求头 `x-ig-app-id` 里，是**公开的网页常量**（不是账号凭据）：
 * 私有的 `/api/v1/...` 接口要求带上它，否则一律 400/404。
 * 会话仍然是网页自己的 cookie（fetch 用 credentials:"include"），原生侧不碰 token。
 */
const IG_APP_ID: string = '936619743392459';

/**
 * Installed at document start. It reports SPA route changes and detects a
 * signed-in session through the page's own navigation landmarks.
 *
 * The authoritative answer lives in the native ArkWeb cookie jar
 * (`InstagramCookieJar`): Instagram's session cookies are HttpOnly, so
 * `document.cookie` can never see them. What this watcher adds is a fast hint
 * from the rendered page, plus the negative signal that only a login form or an
 * `/accounts/...` route can give.
 */
export const SESSION_WATCHER: string = '(function(){try{' +
    'if(window.__ogSessionWatch){return;}window.__ogSessionWatch=1;' +
    'var sendSession=function(value){try{' + PROXY + '.onSessionState(value?"1":"0");}catch(e){}};' +
    'var sendRoute=function(){try{' + PROXY + '.onRouteChange(String(location.href));}catch(e){}};' +
    'var signed=null;' +
    'var detect=function(){try{' +
    'var cookie=document.cookie||"";' +
    'var now=cookie.indexOf("sessionid=")>=0||cookie.indexOf("ds_user_id=")>=0;' +
    'if(!now){' +
    'var path=location.pathname||"";' +
    'var inAuthFlow=path.indexOf("/accounts/login")>=0||path.indexOf("/accounts/signup")>=0||' +
    'path.indexOf("/accounts/emailsignup")>=0||path.indexOf("/accounts/password")>=0||' +
    'path.indexOf("/challenge")>=0;' +
    'var loginForm=!!document.querySelector(\'input[name="username"]\');' +
    'if(!inAuthFlow&&!loginForm){' +
    'now=!!document.querySelector("main article")||' +
    '!!document.querySelector(\'a[href^="/direct/"]\')||' +
    '!!document.querySelector(\'a[href^="/explore/"]\')||' +
    '!!document.querySelector(\'svg[aria-label="Home"]\')||' +
    '!!document.querySelector(\'svg[aria-label="Search"]\')||' +
    '!!document.querySelector(\'svg[aria-label="Reels"]\')||' +
    '!!document.querySelector(\'svg[aria-label="Notifications"]\');}}' +
    'if(now!==signed){signed=now;sendSession(now);}' +
    '}catch(e){}};' +
    'if(!window.__ogHistoryHooked){window.__ogHistoryHooked=1;' +
    'var push=history.pushState;var replace=history.replaceState;' +
    'history.pushState=function(){var result=push.apply(this,arguments);sendRoute();return result;};' +
    'history.replaceState=function(){var result=replace.apply(this,arguments);sendRoute();return result;};' +
    'window.addEventListener("popstate",sendRoute);window.addEventListener("hashchange",sendRoute);}' +
    'try{document.addEventListener("DOMContentLoaded",detect);}catch(e){}' +
    'detect();sendRoute();setInterval(detect,3000);' +
    '}catch(e){}})();';
/** 探针用：把页面滚到底，触发它自己的翻页请求。 */
/** 探针/翻页用：把页面滚到底，触发它自己的翻页请求。 */
export const SCROLL_BOTTOM_SCRIPT: string = '(function(){try{' +
    'var out=[];var count=0;' +
    'var tryScroll=function(el,name){if(!el)return;var before=el.scrollTop||0;' +
    'try{el.scrollTop=el.scrollHeight;}catch(e){}' +
    'if(el.scrollTop>before){count++;out.push(name+"="+Math.round(el.scrollTop));}};' +
    'tryScroll(document.scrollingElement,"se");' +
    'tryScroll(document.documentElement,"html");' +
    'tryScroll(document.body,"body");' +
    'tryScroll(document.querySelector("main"),"main");' +
    'tryScroll(document.querySelector(\'div[role="main"]\'),"roleMain");' +
    'var beforeW=window.scrollY||0;' +
    'try{window.scrollTo(0,document.documentElement.scrollHeight);}catch(e){}' +
    'if((window.scrollY||0)>beforeW){count++;out.push("win="+Math.round(window.scrollY));}' +
    'return "ok:"+count+":"+out.join(",");' +
    '}catch(e){return "scroll-error:"+String(e);}})()';
/**
 * 让页面自己重新拉一次首页 feed。
 *
 * 首屏是 SSR，页面不会主动请求 feed 接口，`window.__ogReplay` 因此是空的。
 * 这个脚本点一下页面里的首页链接（logo / Home 图标），React Router 会重新挂载
 * Home 组件并发出 feed 请求，`NETWORK_WATCHER` 就能记下 cfg 供后续回放。
 */
export const TRIGGER_FEED_SCRIPT: string = '(function(){try{' +
    // 优先点 nav 里的 Home 链接
    'var cands=document.querySelectorAll(\'a[href="/"], a[href="/?"]\');' +
    'for(var i=0;i<cands.length;i++){' +
    'var a=cands[i];try{var r=a.getBoundingClientRect();' +
    'if(r.width>0&&r.height>0){a.click();return "clicked";}}catch(e){}}' +
    // 找不到可见链接就试着点 Home 图标
    'var icons=document.querySelectorAll(\'svg[aria-label="Home"]\');' +
    'if(icons.length>0){try{icons[0].dispatchEvent(new MouseEvent("click",{bubbles:true}));' +
    'return "icon-clicked";}catch(e){}}' +
    // 都没有：路由到首页（如果当前不在首页）
    'if(location.pathname!=="/"){' +
    'try{history.pushState({},"","/");' +
    'window.dispatchEvent(new PopStateEvent("popstate"));' +
    'return "routed-home";}catch(e){}}' +
    'return "no-op";' +
    '}catch(e){return "err:"+String(e);}})()';
/**
 * 生成「回放页面那条首页信息流 GraphQL」的脚本。
 *
 * 用的是页面内存里记下的原始请求（同源、同一份会话），只把 `__req` 换掉，
 * 避免与页面正在进行的请求撞号；不发任何写操作。
 *
 * cursor 为空时回放页面最近一次抓到的那条 feed 请求；非空时把 `variables.after`
 * 换成指定游标再发 —— 这样翻页可以直接要下一页，不必再滚页面、等页面自己发请求。
 *
 * 返回里带上 `page_info` 的 nextCursor / hasMore，原生侧据此判断「到底还有没有
 * 下一页」，而不是拿「这次回放没新增」去猜。
 */
export function timelineScript(cursor: string): string {
    const cursorLiteral: string = JSON.stringify(cursor);
    return '(async function(){try{' +
        'var CURSOR=' + cursorLiteral + ';' +
        'var KEY="xdt_api__v1__feed__timeline__connection";' +
        'var unescapeQuotes=function(s){var out="";var i=0;' +
        'while(i<s.length){var j=s.indexOf("\\\\",i);' +
        'if(j<0){out+=s.substring(i);break;}' +
        'out+=s.substring(i,j);var n=s.charCodeAt(j+1);' +
        'out+=String.fromCharCode(n===34?34:(n||92));i=j+2;}' +
        'return out;};' +
        'var parseAt=function(t){var q="\\""+KEY+"\\"";' +
        'for(var at=t.indexOf(q);at>=0;at=t.indexOf(q,at+1)){' +
        'var brace=t.indexOf("{",at+q.length);if(brace<0)break;' +
        'var depth=0;var inStr=false;var esc=false;' +
        'for(var k=brace;k<t.length;k++){var c=t.charAt(k);' +
        'if(inStr){if(esc){esc=false;}else if(c==="\\\\"){esc=true;}else if(c==="\\""){inStr=false;}continue;}' +
        'if(c==="\\""){inStr=true;continue;}' +
        'if(c==="{"){depth++;}else if(c==="}"){depth--;' +
        'if(depth===0){try{return JSON.parse(t.substring(brace,k+1));}catch(e){}break;}}}}' +
        'return null;};' +
        'var extractConn=function(){try{var ss=document.querySelectorAll("script");' +
        'for(var i=0;i<ss.length;i++){var t=ss[i].textContent||"";' +
        'var hit=t.indexOf(KEY);if(hit<0)continue;' +
        'var r=parseAt(t);if(r)return r;' +
        'var win=t.substring(hit>500?hit-500:0, Math.min(t.length,hit+500000));' +
        'try{r=parseAt(unescapeQuotes(win));if(r)return r;}catch(e){}' +
        '}' +
        '}catch(e){}return null;};' +
        'var ssrProbe=function(){var out={hit:0,scripts:0};' +
        'try{var ss=document.querySelectorAll("script");out.scripts=ss.length;' +
        'for(var i=0;i<ss.length;i++){var t=ss[i].textContent||"";if(t.indexOf(KEY)>=0)out.hit++;}}catch(e){}' +
        'return out;};' +
        // __ogFeedCfg 是 NETWORK_WATCHER 为首页信息流单独维护的「最近一次」槽位。
        // 早先按名字在 __ogReplay 里翻找，会命中最旧那条（首屏水合时那条），于是每次
        // 翻页都回放第一页 —— 表现就是触底半天没动静、然后被告知「没有更多帖子了」。
        'var cfg=window.__ogFeedCfg||null;' +
        'if(!cfg){var rep=window.__ogReplay||{};var names=Object.keys(rep);' +
        'for(var n=0;n<names.length;n++){' +
        'if(names[n].indexOf("FeedTimeline")>=0||names[n].indexOf("FeedRootPagination")>=0){' +
        'cfg=rep[names[n]];break;}}}' +
        // 翻页用：把 variables.after 换成目标游标。取不到 variables 就回 no-cursor-slot，
        // 原生侧会退回「滚页面逼它自己发请求」这条老路。
        'var setCursor=function(body,cur){try{' +
        'var parts=String(body||"").split("&");' +
        'for(var i=0;i<parts.length;i++){' +
        'if(parts[i].indexOf("variables=")!==0)continue;' +
        'var obj=JSON.parse(decodeURIComponent(parts[i].substring(10)));' +
        'if(!obj||typeof obj!=="object")return null;' +
        'obj.after=cur;' +
        'parts[i]="variables="+encodeURIComponent(JSON.stringify(obj));' +
        'return parts.join("&");}}catch(e){}' +
        'return null;};' +
        'var conn=null;var http=200;var src="";' +
        // 取一条请求体里 variables.after 的值（判断"这份响应是回答哪个游标的"）。
        'var cursorOf=function(body){try{' +
        'var m=String(body||"").match(/variables=([^&]*)/);if(!m)return "";' +
        'var o=JSON.parse(decodeURIComponent(m[1]));' +
        'return (o&&o.after)?String(o.after):"";}catch(e){return "";}};' +
        // ---- 快路径：直接用页面自己那条请求的响应（不再发一次 fetch）----
        //
        // 游标必须对得上：请求的是"下一页"时，手里这份首屏响应没用。
        // 只有真的从里面解出了 timeline 连接才算命中，并把这份消耗掉（否则下次刷新
        // 会拿到同一份旧数据 —— 刷新要的永远是新的）。
        //
        // CAP_OFF 是**给真机做 A/B 用的开关**（默认 0 = 用快路径）：把它改成 1 重装，
        // 走的就完全是改动前那条"等信号 → 回放"的老路，日志里的 first round=N ms= 就是对比数据。
        // 实测冷启动首屏拿到真·第一页：快路径 3.4~4.1s，老路 11~20s（老路常常前两轮 signal
        // 全是 timeout，等满了才开始回放）。
        'var CAP_OFF=0;var cap=null;try{if(!CAP_OFF)cap=(window.__ogCap||{}).feed||null;}catch(e){}' +
        'if(cap&&String(cap.t||"").length>0&&cursorOf(cap.b)===String(CURSOR||"")){' +
        'try{var cj=JSON.parse(String(cap.t));conn=cj&&cj.data?cj.data[KEY]:null;}catch(e){}' +
        'if(conn){src="capture";try{delete window.__ogCap.feed;}catch(e){}}' +
        '}' +
        'if(cfg&&!conn){' +
        'var headers={};for(var h=0;h<cfg.h.length;h++){headers[cfg.h[h][0]]=cfg.h[h][1];}' +
        'var body=String(cfg.b||"");' +
        'if(CURSOR){var patched=setCursor(body,CURSOR);' +
        'if(patched===null)return JSON.stringify({state:"no-cursor-slot",src:"none"});' +
        'body=patched;}' +
        'body=body.replace(/__req=[^&]*/,"__req="+Math.random().toString(36).slice(2,4));' +
        'var res=null;' +
        // 给这一发打上「安静」标记（见 NETWORK_WATCHER 里 quiet 那段说明）：回放的请求
        // 不进 __ogFeedCfg，兜底路径才能回放到页面自己刚发的那一页。
        'var ac=new AbortController();var tm=setTimeout(function(){ac.abort();},9000);' +
        'var init={method:cfg.m||"POST",credentials:"include",headers:headers,body:body,' +
        'signal:ac.signal};try{init.__ogQuiet=1;}catch(e){}' +
        'try{res=await fetch(cfg.u,init);clearTimeout(tm);}catch(e){res=null;}' +
        'if(res){' +
        'http=res.status;' +
        'var txt=await res.text();' +
        'var json=null;try{json=JSON.parse(txt);}catch(e){}' +
        'try{conn=json&&json.data?json.data["xdt_api__v1__feed__timeline__connection"]:null;}catch(e){}' +
        'if(conn)src="replay";' +
        '}' +
        '}' +
        // 只有首屏（没指定游标）才退到 SSR 内嵌数据：翻页时页面里没有下一页。
        'if(!conn&&!CURSOR){var ssrConn=extractConn();if(ssrConn){conn=ssrConn;src="ssr";}}' +
        'if(!conn)return JSON.stringify({state:"empty",http:http,cfg:!!cfg,src:src,ssr:ssrProbe()});' +
        // pickImage / pickVideo 除了地址，还把「这张图/这个视频本身的尺寸」带出来：
        // 原生侧要按真实宽高比排版（原来一律裁成正方形），接口里就有现成的数字，不必猜。
        // 挑选规则见 MEDIA_PICK_JS（展示降级到 1080 档、original=true 取最大档给下载用）。
        MEDIA_PICK_JS +
        'var mapMedia=function(m){var images=[];var orig=[];var video="";var origVideo="";' +
        'var iw=0;var ih=0;var vw=0;var vh=0;' +
        'if(m.carousel_media&&m.carousel_media.length){' +
        'for(var i=0;i<m.carousel_media.length&&i<10;i++){var c=m.carousel_media[i];' +
        'var u=pickImage(c.image_versions2,false);var uo=pickImage(c.image_versions2,true);' +
        'if(u.url){images.push(u.url);orig.push(uo.url||u.url);if(!iw){iw=u.w;ih=u.h;}}' +
        'if(!video){var v=pickVideo(c,false);video=v.url;vw=v.w;vh=v.h;' +
        'var vb=pickVideo(c,true);origVideo=vb.url;}}' +
        '}else{var one=pickImage(m.image_versions2,false);var oneo=pickImage(m.image_versions2,true);' +
        'if(one.url){images.push(one.url);orig.push(oneo.url||one.url);iw=one.w;ih=one.h;}' +
        'var v1=pickVideo(m,false);video=v1.url;vw=v1.w;vh=v1.h;' +
        'var v1b=pickVideo(m,true);origVideo=v1b.url;}' +
        // 帖子的 original_width/height 才是这条媒体的真实比例，优先用它；
        // 没有就退回选中图片的尺寸，再没有才退回视频尺寸。都拿不到时给 0，原生侧按正方形兜底。
        'var ow=Number(m.original_width)||0;var oh=Number(m.original_height)||0;' +
        'if(!(ow>0&&oh>0)){ow=iw;oh=ih;}' +
        'if(!(ow>0&&oh>0)){ow=vw;oh=vh;}' +
        'return {images:images,origImages:orig,video:video,origVideo:origVideo,w:ow,h:oh};};' +
        // 转发数 / 分享数：网页界面上并没有专门渲染这两个数字（网页版连转发按钮都没有），
        // 只能回到接口节点里找。字段名不确定，所以按「名字里含 repost/reshare 或 share、
        // 且值确实是数字」来取 —— 与形状无关，Instagram 改名字也能跟着走。
        // 命中不到就是 0，原生侧不显示该计数。namesByRe 会把命中的字段名回传，便于确认。
        // 值的形态也不能想当然：可能是数字，也可能是 "239" / "1,234" / "1.2K" 这样的字符串，
        // 还可能被包一层对象（`{count: 3}` / `{total_count: 3}`）—— 三种都认。
        'var asNum=function(v){if(typeof v==="number")return v>0?v:0;' +
        'if(typeof v==="string"){var s=v.replace(/[,\\s]/g,"");' +
        'var m=/^([0-9]+(?:\\.[0-9]+)?)([KkMmBb])?$/.exec(s);if(!m)return 0;' +
        'var n=Number(m[1]);var u=(m[2]||"").toLowerCase();' +
        'if(u==="k")n*=1e3;else if(u==="m")n*=1e6;else if(u==="b")n*=1e9;' +
        'return n>0?Math.round(n):0;}' +
        'if(v&&typeof v==="object"){var ks=["count","total_count","total","value","count_aggregate"];' +
        'for(var i=0;i<ks.length;i++){var r=asNum(v[ks[i]]);if(r>0)return r;}}' +
        'return 0;};' +
        // 这两个字段不一定挂在最外层，所以在有界深度内再往下找一层（只认键名匹配的）。
        'var numByRe=function(o,re,ex,depth){try{' +
        'for(var k in o){if(!re.test(k))continue;' +
        // reshare_count 这种同时含 share 的字段要排除掉，否则转发数会被当成分享数取两遍。
        'if(ex&&ex.test(k))continue;var v=asNum(o[k]);if(v>0)return v;}' +
        'if(depth>0){for(var k2 in o){var v2=o[k2];' +
        'if(v2&&typeof v2==="object"&&!Array.isArray(v2)){' +
        'var r=numByRe(v2,re,ex,depth-1);if(r>0)return r;}}}}catch(e){}return 0;};' +
        'var namesByRe=function(o,re,ex,depth){try{var out=[];' +
        'for(var k in o){if(!re.test(k))continue;if(ex&&ex.test(k))continue;' +
        'var v=asNum(o[k]);if(v>0)out.push(k+"="+v);}' +
        'if(depth>0){for(var k2 in o){var v2=o[k2];' +
        'if(v2&&typeof v2==="object"&&!Array.isArray(v2)){' +
        'var sub=namesByRe(v2,re,ex,depth-1);if(sub.length>0)out.push(k2+"."+sub);}}}' +
        'return out.join(",");}catch(e){return "";}};' +
        // 诊断用：把所有「像计数」的键连值一起倒出来 —— 字段名猜不中时，靠它直接定位。
        'var keyDump=function(o){try{var out=[];' +
        'var put=function(k,v){if(!/count|share|shar|repost|reshare/i.test(k))return;' +
        'if(v===null||v===undefined)return;' +
        'out.push(k+"="+(typeof v==="object"?"obj":String(v).slice(0,12)));};' +
        'for(var k in o)put(k,o[k]);' +
        'for(var k2 in o){var v2=o[k2];' +
        'if(v2&&typeof v2==="object"&&!Array.isArray(v2)){' +
        'for(var k3 in v2)put(k2+"."+k3,v2[k3]);}}' +
        'return out.slice(0,20).join(",");}catch(e){return "";}};' +
        'var REPOST_RE=/repost|reshare/i;var SHARE_RE=/share/i;' +
        'var edges=conn.edges||[];var items=[];' +
        // 信息流里混着「推荐」卡片：它们的 node.media 是 null，真正的帖子挂在
        // node.explore_story.media 上。早先只认 node.media，这些卡片被整片丢掉，
        // 列表里就只剩少数几条关注账号的帖子。
        'for(var e=0;e<edges.length;e++){' +
        'var nd=edges[e]?edges[e].node:null;var m=nd?nd.media:null;' +
        'if(!m&&nd&&nd.explore_story)m=nd.explore_story.media||null;' +
        'if(!m)continue;var med=mapMedia(m);var code=String(m.code||"");' +
        'var type=Number(m.media_type)||1;' +
        'var kind=(type===2||med.video.length>0)?"reel":"p";' +
        'items.push({id:String(m.id||code),shortcode:code,' +
        'username:m.user?String(m.user.username||""):"",' +
        'avatar:m.user?String(m.user.profile_pic_url||""):"",' +
        'caption:m.caption?String(m.caption.text||""):"",' +
        'images:med.images,videoUrl:med.video,poster:(med.images.length>0?med.images[0]:""),' +
        // 下载用的原始地址（最大的一档）：展示用的那份已经降到 1080 档了。
        'originalImages:med.origImages,originalVideo:med.origVideo,' +
        // 媒体原始宽高：原生侧据此按真实比例排版，不再裁成正方形。
        'w:med.w,h:med.h,' +
        'permalink:code.length>0?("https://www.instagram.com/"+kind+"/"+code+"/"):"",' +
        'likes:Number(m.like_count)||0,comments:Number(m.comment_count)||0,' +
        'views:Number(m.view_count)||0,liked:!!m.has_liked,takenAt:(Number(m.taken_at)||0)*1000,' +
        'reposts:numByRe(m,REPOST_RE,null,1),shares:numByRe(m,SHARE_RE,REPOST_RE,1)});}' +
        // 第一个节点的字段名清单，只用于诊断：命中的键 + 所有「像计数」的键与值。
        'var dbg="";try{' +
        'var m0=(edges.length>0&&edges[0].node)?edges[0].node.media:null;' +
        'if(m0)dbg="rp["+namesByRe(m0,REPOST_RE,null,1)+"] sh["' +
        '+namesByRe(m0,SHARE_RE,REPOST_RE,1)+"] keys["+keyDump(m0)+"]";' +
        '}catch(e){}' +
        'var pi=conn.page_info||{};' +
        'var nextCursor=pi.end_cursor?String(pi.end_cursor):"";' +
        // hasNext 只在服务端明确给出布尔值时才带上。SSR 内嵌数据往往没有 page_info，
        // 那种「没有依据」绝不能当成「没有下一页」，否则翻页会被永久锁死。
        'var hasNext=(typeof pi.has_next_page==="boolean")?pi.has_next_page:null;' +
        'var out={state:items.length>0?"ok":"empty",items:items,url:location.href,src:src,' +
        'debug:dbg,nextCursor:nextCursor,hasMore:(hasNext===null)?(nextCursor.length>0):hasNext};' +
        'if(hasNext!==null)out.hasNext=hasNext;' +
        'return JSON.stringify(out);' +
        '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}
export const TIMELINE_PROBE_SCRIPT: string = '(async function(){try{' +
    'var rep=window.__ogReplay||{};' +
    'var name="PolarisFeedTimelineRootV2Query";' +
    'var cfg=rep[name];' +
    'var route={path:location.pathname,watch:!!window.__ogNetWatch,names:Object.keys(rep).slice(0,24)};' +
    'if(!cfg){' +
    // 还没抓到这条请求时，回一份 DOM 侧摘要，报告里至少能看到当时页面有什么。
    'var arts=document.querySelectorAll("main article");' +
    'var imgs=0;var alt="";' +
    'if(arts.length>0){var im=arts[0].querySelectorAll("img");imgs=im.length;' +
    'for(var k=0;k<im.length&&!alt;k++){var a=String(im[k].getAttribute("alt")||"");if(a)alt=a.slice(0,40);}}' +
    'return JSON.stringify({state:"no-config",route:route,articles:arts.length,firstImgs:imgs,firstAlt:alt});' +
    '}' +
    'var headers={};' +
    'for(var i=0;i<cfg.h.length;i++){headers[cfg.h[i][0]]=cfg.h[i][1];}' +
    'var body=String(cfg.b||"").replace(/__req=[^&]*/,"__req="+Math.random().toString(36).slice(2,4));' +
    'var res=await fetch(cfg.u,{method:cfg.m||"POST",credentials:"include",headers:headers,body:body});' +
    'var txt=await res.text();' +
    'var json=null;try{json=JSON.parse(txt);}catch(e){}' +
    'if(!json)return JSON.stringify({state:"bad-json",http:res.status,len:txt.length,sample:txt.slice(0,200)});' +
    'var root=json.data?json.data["xdt_api__v1__feed__timeline__connection"]:null;' +
    'var edges=root&&root.edges?root.edges:[];' +
    'var media=edges.length&&edges[0].node?edges[0].node.media:null;' +
    'var keys=function(o){try{return o?Object.keys(o):[];}catch(e){return [];}};' +
    'var iv=media?(media.image_versions2||media.image_versions||null):null;' +
    'var cands=iv&&iv.candidates?iv.candidates:[];' +
    'var first=media||{};' +
    'var digest={state:"ok",http:res.status,edges:edges.length,done:root?!!root.page_info:false,' +
    'mediaKeys:keys(media),userKeys:keys(first.user),ivKeys:keys(iv),candKeys:keys(cands.length?cands[0]:null),' +
    'captionKeys:keys(first.caption),carousel:first.carousel_media?first.carousel_media.length:0,' +
    'code:first.code||"",mediaType:first.media_type||0,likeCount:first.like_count||0,' +
    'commentCount:first.comment_count||0,takenAt:first.taken_at||0,hasLiked:!!first.has_liked,' +
    'playCount:first.play_count||0,candCount:cands.length,' +
    'sampleUrl:cands.length?String(cands[0].url||"").slice(0,90):""};' +
    'return JSON.stringify(digest);' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
/**
 * Reads the visible home feed from Instagram's rendered DOM.
 *
 * This intentionally stays on the page's own origin and avoids private APIs:
 * the WebView already has the real cookies, CSRF state and hydration data, and
 * Instagram remains responsible for lazy-loading the feed.
 */
const FEED_SCRIPT_LEGACY: string = '(async function(){try{' +
    'var clean=function(v){return String(v==null?"":v).replace(/\\s+/g," ").trim();};' +
    'var abs=function(href){try{return new URL(href,location.origin).href;}catch(e){return String(href||"");}};' +
    'var number=function(v){try{' +
    'var s=String(v||"").replace(/,/g,"");' +
    'var m=s.match(/([0-9]+(?:\\.[0-9]+)?)\\s*([万wkmK])?/);' +
    'if(!m)return 0;var n=parseFloat(m[1]);var unit=(m[2]||"").toLowerCase();' +
    'if(unit==="万"||unit==="w")n*=10000;else if(unit==="k")n*=1000;else if(unit==="m")n*=1000000;' +
    'return Math.round(n);}catch(e){return 0;}};' +
    'var pushUnique=function(list,value){if(value&&list.indexOf(value)<0)list.push(value);};' +
    'var articleText=function(article){try{return clean(article.innerText||article.textContent||"");}catch(e){return "";}};' +
    'var readAuthor=function(article){' +
    'var header=article.querySelector("header");var username="";var avatar="";var profileUrl="";' +
    'if(header){var link=header.querySelector(\'a[href^="/"]\');' +
    'if(link){username=clean(link.textContent).replace(/^@/,"");profileUrl=abs(link.getAttribute("href")||"");}' +
    'var img=header.querySelector("img[src]");if(img)avatar=img.currentSrc||img.src||"";}' +
    'if(!username){var alt=header&&header.querySelector("img[alt]");' +
    'if(alt)username=clean(alt.getAttribute("alt")).replace(/ profile picture/i,"").replace(/^@/,"");}' +
    'return {username:username,avatar:avatar,profileUrl:profileUrl};};' +
    'var readMedia=function(article,author){' +
    'var images=[];var nodes=article.querySelectorAll("img[src]");' +
    'for(var i=0;i<nodes.length;i++){var img=nodes[i];var src=img.currentSrc||img.src||"";' +
    'var alt=clean(img.getAttribute("alt")).toLowerCase();' +
    'if(!src||src.indexOf("data:")===0||alt.indexOf("profile picture")>=0)continue;' +
    'var rect=img.getBoundingClientRect();' +
    'if(rect.width>=140||img.naturalWidth>=420||nodes.length<=2)pushUnique(images,src);}' +
    'var video=article.querySelector("video");var videoUrl="";var poster="";' +
    'if(video){videoUrl=video.currentSrc||video.src||"";poster=video.poster||"";pushUnique(images,poster);}' +
    'var permalink="";var links=article.querySelectorAll(\'a[href*="/p/"],a[href*="/reel/"],a[href*="/tv/"]\');' +
    'if(links.length>0)permalink=abs(links[0].getAttribute("href")||"");' +
    'var caption="";var candidates=article.querySelectorAll(\'h1,span[dir="auto"]\');' +
    'for(var c=0;c<candidates.length;c++){var candidate=candidates[c];' +
    'if(candidate.children&&candidate.children.length>0)continue;' +
    'var value=clean(candidate.textContent);' +
    'if(value.length>caption.length&&value.length<=2200&&' +
    'value.indexOf(author.username)!==0&&value.indexOf("查看翻译")<0)caption=value;}' +
    'return {images:images,videoUrl:videoUrl,poster:poster,permalink:permalink,caption:caption};};' +
    'var readCounts=function(article){' +
    'var likes=0;var comments=0;var all=article.querySelectorAll("span,button");' +
    'for(var i=0;i<all.length;i++){var value=clean(all[i].getAttribute("aria-label")||all[i].textContent);' +
    'if(!likes&&/(次赞|個讚|likes?)/i.test(value))likes=number(value);' +
    'if(!comments&&/(条评论|則留言|comments?)/i.test(value))comments=number(value);}' +
    'return {likes:likes,comments:comments};};' +
    'var articles=document.querySelectorAll("main article");' +
    'if(articles.length===0){await new Promise(function(resolve){setTimeout(resolve,1200);});}' +
    'articles=document.querySelectorAll("main article");' +
    'var items=[];' +
    'for(var a=0;a<articles.length;a++){var article=articles[a];var author=readAuthor(article);' +
    'var media=readMedia(article,author);var counts=readCounts(article);' +
    'var shortcode="";if(media.permalink){var match=media.permalink.match(/\\/(?:p|reel|tv)\\/([^\\/?#]+)/);' +
    'if(match)shortcode=match[1];}' +
    'if(!author.username&&!media.images.length&&!media.caption)continue;' +
    'items.push({id:shortcode||("post-"+a),shortcode:shortcode,username:author.username,' +
    'avatar:author.avatar,caption:media.caption,images:media.images,videoUrl:media.videoUrl,' +
    'poster:media.poster,permalink:media.permalink,likes:counts.likes,comments:counts.comments,' +
    'reposts:counts.reposts,shares:counts.shares});}' +
    'return JSON.stringify({state:items.length?"ok":"empty",items:items,url:location.href});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,180)});}})()';
/**
 * 读取首页信息流（DOM 抽取，当前生产用）。
 *
 * Instagram 的首屏是 SSR 出来的，页面自己不会发「首页信息流」那条接口，
 * 所以首屏只能读页面已经渲染好的结构；作者名取自头像的 alt，媒体按
 * cdninstagram 媒体图（排除头像图）里面积最大的那张当封面。
 */
export const FEED_SCRIPT: string = '(async function(){try{' +
    'var clean=function(v){return String(v==null?"":v).replace(/\\s+/g," ").trim();};' +
    'var abs=function(href){try{return new URL(href,location.origin).href;}catch(e){return String(href||"");}};' +
    'var number=function(v){try{var s=String(v||"").replace(/,/g,"");' +
    'var m=s.match(/([0-9]+(?:\\.[0-9]+)?)\\s*([万wkmK])?/);if(!m)return 0;' +
    'var n=parseFloat(m[1]);var u=(m[2]||"").toLowerCase();' +
    'if(u==="万"||u==="w")n*=10000;else if(u==="k")n*=1000;else if(u==="m")n*=1000000;' +
    'return Math.round(n);}catch(e){return 0;}};' +
    // 头像的 alt 就是用户名（"muyan.official的头像" / "jaychou\'s profile picture"）。
    'var nameFromAlt=function(alt){var a=clean(alt);if(!a)return "";' +
    'a=a.replace(/(\\u2019s|\'s|的)?\\s*(profile picture|头像|个人资料照片|个人资料图片|的头像照片)$/i,"");' +
    'a=a.replace(/^@/,"").trim();return a.length>0&&a.length<=40?a:"";};' +
    'var isAvatarUrl=function(url){var u=String(url||"");' +
    // 只认头像目录（t51.2885-19 / profile_pic）。媒体图与视频封面可能带 s150x150
    // 之类的 stp 参数，用尺寸关键字判断会把正文图片一起误杀。
    'return u.indexOf("t51.2885-19")>=0||u.indexOf("profile_pic")>=0;};' +
    'var readAuthor=function(article){' +
    'var username="";var avatar="";var profileUrl="";' +
    // 当前版式里帖子没有 <header>：头像 alt 与作者链接直接挂在 article 上。
    'var imgs=article.querySelectorAll("img");' +
    'for(var i=0;i<imgs.length;i++){var src=imgs[i].currentSrc||imgs[i].src||"";' +
    'if(!avatar&&src&&isAvatarUrl(src))avatar=src;' +
    'if(!username&&isAvatarUrl(src)){var n=nameFromAlt(imgs[i].getAttribute("alt"));if(n)username=n;}}' +
    'if(!username||!profileUrl){var links=article.querySelectorAll(\'a[href^="/"]\');' +
    'for(var j=0;j<links.length;j++){var h=links[j].getAttribute("href")||"";' +
    'if(h.length<2||h.indexOf("/",1)>=0)continue;' +
    'var t=clean(links[j].textContent);' +
    'if(profileUrl.length===0)profileUrl=abs(h);' +
    'if(username.length===0&&t.length>0&&t.length<=30&&!/验证|verified/i.test(t)){' +
    'username=t.replace(/^@/,"");break;}}}' +
    'if(!username){var all=article.querySelectorAll("img[alt]");' +
    'for(var k=0;k<all.length;k++){var n2=nameFromAlt(all[k].getAttribute("alt"));if(n2){username=n2;break;}}}' +
    'return {username:username,avatar:avatar,profileUrl:profileUrl};};' +
    'var readMedia=function(article){' +
    'var images=[];var seen={};var best="";var bestArea=0;' +
    'var nodes=article.querySelectorAll("img");' +
    'for(var i=0;i<nodes.length;i++){var img=nodes[i];var src=img.currentSrc||img.src||"";' +
    'if(!src||src.indexOf("data:")===0||isAvatarUrl(src))continue;' +
    'var r=null;try{r=img.getBoundingClientRect();}catch(e){}' +
    'if(r&&r.width>0&&r.width<150)continue;' +
    'var area=r?Math.round(r.width*r.height):0;' +
    'if(area>bestArea){bestArea=area;best=src;}' +
    'var key=src.split("?")[0];if(!seen[key]){seen[key]=1;if(images.length<10)images.push(src);}}' +
    'if(best.length>0){var at=images.indexOf(best);if(at>0){images.splice(at,1);images.unshift(best);}}' +
    'var video="";var poster="";var v=article.querySelector("video");' +
    'if(v){video=v.currentSrc||v.src||"";poster=v.poster||"";}' +
    // 视频帖常见形态：画面是 <video> + poster 图，媒体图还没挂上。
    'if(images.length===0&&poster.length>0)pushUniqueImage(images,seen,poster);' +
    'var permalink="";var links=article.querySelectorAll(\'a[href*="/p/"],a[href*="/reel/"],a[href*="/tv/"]\');' +
    'if(links.length>0)permalink=abs(links[0].getAttribute("href")||"");' +
    'return {images:images,videoUrl:video,poster:poster,permalink:permalink};};' +
    'function pushUniqueImage(list,seen,src){var k=String(src).split("?")[0];' +
    'if(k.length===0||seen[k])return;seen[k]=1;if(list.length<10)list.push(src);}' +
    'var readCaption=function(article,username){var best="";' +
    // 正文节点里常把"更多 / 查看翻译"这类入口也塞在同一节点里，尾巴上要去掉，
    // 否则原生侧会把"展开"这两个字当成正文的一部分。
    'var stripTail=function(v){var s=clean(v);' +
    's=s.replace(/\\s*(查看翻译|看到翻译|查看原文|See translation|更多|展开|more)\\s*$/ig,"");' +
    'return s.replace(/\\s+$/,"");};' +
    'var nodes=article.querySelectorAll(\'h1,span[dir="auto"],div[dir="auto"]\');' +
    'for(var i=0;i<nodes.length;i++){var n=nodes[i];' +
    'var t=stripTail(n.textContent);' +
    // 上限放到 6000：IG 正文上限是 2200 字符，但节点里可能混进额外文本，
    // 卡在 2200 会把长正文整条跳过（原来就是这么丢正文的）。
    'if(t.length<=best.length||t.length>6000)continue;' +
    'if(username.length>0&&t.indexOf(username)===0)continue;' +
    'if(/^(赞|回复|查看更多|查看翻译|View|Reply|Like|More|·)/i.test(t))continue;' +
    'if(/^[0-9.,]+\\s*[万亿wkm]?$/i.test(t))continue;best=t;}' +
    'return best;};' +
    'var readCounts=function(article){var likes=0;var comments=0;var reposts=0;var shares=0;var nums=[];' +
    'var nodes=article.querySelectorAll("button,span,a");' +
    'for(var i=0;i<nodes.length;i++){var n=nodes[i];' +
    'var t=clean(n.getAttribute("aria-label"));if(t.length===0)t=clean(n.textContent);if(t.length===0)continue;' +
    'if(/(次赞|個讚|likes)/i.test(t)){if(likes===0)likes=number(t);continue;}' +
    'if(/(条评论|則留言|comments)/i.test(t)){if(comments===0)comments=number(t);continue;}' +
    // 转发 / 分享：网页版不一定渲染这两个数字，能读到就读，读不到留 0（界面不显示）。
    'if(/(转发|轉發|reposts?|reshare)/i.test(t)){if(reposts===0)reposts=number(t);continue;}' +
    'if(/(分享|shares?)/i.test(t)){if(shares===0)shares=number(t);continue;}' +
    'if(t.length<=12&&/^[0-9][0-9.,]*\\s*[万亿wkm]?$/i.test(t)&&nums.indexOf(t)<0)nums.push(t);}' +
    // 这一版统计行是「6.4 万 / 173 / 3,015」这样的纯数字：第一个当赞数，第二个当评论数。
    'if(likes===0&&nums.length>0)likes=number(nums[0]);' +
    'if(comments===0&&nums.length>1)comments=number(nums[1]);' +
    'if(reposts===0&&nums.length>2)reposts=number(nums[2]);' +
    'if(shares===0&&nums.length>3)shares=number(nums[3]);' +
    'return {likes:likes,comments:comments,reposts:reposts,shares:shares};};' +
    // 发布时间（原生侧要显示"post 了多久"）。
    // 首选 <time datetime="...">：页面把绝对时间放在这个属性上（ISO 串，Date.parse 直接吃）。
    // 个别版本的卡片只渲染相对文本（"3小时" / "2 days ago"），那就按它反推一个时间。
    // 两种都拿不到就返回 0 —— 原生侧对 0 的处理是**不显示这一行**，而不是瞎猜一个时间。
    'var readTime=function(article){' +
    'var nodes=article.querySelectorAll("time");var raw="";var text="";' +
    'for(var i=0;i<nodes.length&&!raw;i++){' +
    'raw=clean(nodes[i].getAttribute("datetime")||nodes[i].getAttribute("title")||"");' +
    'if(!raw)text=clean(nodes[i].textContent||"");}' +
    'var ts=raw?Date.parse(raw):NaN;' +
    'if(!isNaN(ts)&&ts>0)return ts;' +
    'var m=text.match(/^([0-9]+)\\s*(秒|分钟|分|小时|時|天|日|周|週|个月|月|年|mo|min|sec|hr|s|m|h|d|w|y)/i);' +
    'if(!m)return 0;var n=parseFloat(m[1]);if(!n)return 0;var u=m[2].toLowerCase();var unit=0;' +
    'if(u==="秒"||u==="sec"||u==="s")unit=1000;' +
    'else if(u==="分钟"||u==="分"||u==="min"||u==="m")unit=60000;' +
    'else if(u==="小时"||u==="時"||u==="hr"||u==="h")unit=3600000;' +
    'else if(u==="天"||u==="日"||u==="d")unit=86400000;' +
    'else if(u==="周"||u==="週"||u==="w")unit=604800000;' +
    'else if(u==="个月"||u==="月"||u==="mo")unit=2592000000;' +
    'else if(u==="年"||u==="y")unit=31536000000;' +
    'if(unit<=0)return 0;return Date.now()-n*unit;};' +
    'var articles=document.querySelectorAll("main article");' +
    'if(articles.length===0){await new Promise(function(ok){setTimeout(ok,900);});' +
    'articles=document.querySelectorAll("main article");}' +
    // 懒加载的媒体图可能晚一步才挂上，先等一拍再抽。
    'await new Promise(function(ok){setTimeout(ok,600);});' +
    'articles=document.querySelectorAll("main article");' +
    'var items=[];' +
    'var debug=[];' +
    'for(var a=0;a<articles.length;a++){var art=articles[a];var au=readAuthor(art);var md=readMedia(art);' +
    'var sc=readCounts(art);var cap=readCaption(art,au.username);' +
    'if(a<3){var imgsAll=art.querySelectorAll("img");var vidsAll=art.querySelectorAll("video");' +
    'debug.push("a"+a+":img"+imgsAll.length+"/vid"+vidsAll.length+"/m"+md.images.length+' +
    '"/"+String(md.videoUrl.length>0?1:0)+(md.poster.length>0?"/p1":"/p0")+' +
    '"/vsrc"+(md.videoUrl.length>0?md.videoUrl.slice(0,14):"-")+' +
    '"/img"+(md.images.length>0?md.images[0].slice(0,28):"-")+' +
    // tn = 页面里 <time> 节点的个数，t = 有没有解析出时间。
    // 这一行是"发布时间没显示"时的判据：tn>0 说明有节点但没解析出来，tn=0 说明页面根本没渲染。
    '"/tn"+art.querySelectorAll("time").length+"/t"+(readTime(art)>0?"1":"0"));}' +
    'var code="";if(md.permalink.length>0){var m=md.permalink.match(/\\/(?:p|reel|tv)\\/([^\\/?#]+)/);if(m)code=m[1];}' +
    // 没有媒体图的 article 不是帖子（例如只带头像的推荐位），直接跳过。
    'if(md.images.length===0&&md.videoUrl.length===0)continue;' +
    'items.push({id:code.length>0?code:("post-"+a),shortcode:code,username:au.username,avatar:au.avatar,' +
    'caption:cap,images:md.images,videoUrl:md.videoUrl,poster:md.poster,permalink:md.permalink,' +
    'likes:sc.likes,comments:sc.comments,reposts:sc.reposts,shares:sc.shares,' +
    'takenAt:readTime(art),' +
    'hasVideo:md.videoUrl.length>0||md.poster.length>0});}' +
    'return JSON.stringify({state:items.length>0?"ok":"empty",items:items,url:location.href,' +
    'debug:debug.join(" ")});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,180)});}})()';
/**
 * Finds the signed-in account's own profile link in the page navigation.
 *
 * 路径判定改成「去掉首尾斜杠后不能再有斜杠」：`/username` 与 `/username/` 都认
 *（Instagram 的导航链接是**带尾斜杠**的那种，原来的 `href.indexOf("/",1)>=0`
 * 会把它判掉，于是 Profile 标签总是回落首页），而 `/p/xxx/`、`/explore/tags/x/`
 * 这类多段路径仍然会被排除。
 *
 * 但光这样不够：`/explore/`、`/reels/` 这类**保留路由**也是单段路径。原来它们是被
 * 尾斜杠判据"顺带"挡掉的，放宽后就可能被当成个人页 —— 于是必须显式排除保留字
 *（这些名字 Instagram 不允许当用户名，所以排除它们不会误伤真实账号）。
 *
 * 同时改成两轮查找：先找 alt 明确写着账号头像的（Instagram 会把 alt 设成
 * "xxx 的头像" / "xxx's profile picture"），没有再退到「任意带图的单段链接」。
 * 原来两条判据是 `||` 连在一起的，侧栏里别的用户会抢先命中。
 */
export const OWN_PROFILE_SCRIPT: string = '(function(){try{' +
    'var RESERVED=/^(explore|reels|reel|p|tv|stories|direct|notifications|accounts|create|' +
    'settings|your_activity|about|legal|api|developer|challenge|session|web|directory|emailsignup)$/i;' +
    'var singleSeg=function(h){' +
    'if(!h||h.charAt(0)!=="/")return "";' +
    'var rest=h.substring(1);' +
    'if(rest.charAt(rest.length-1)==="/")rest=rest.substring(0,rest.length-1);' +
    'if(rest.length===0||rest.indexOf("/")>=0)return "";' +
    'if(RESERVED.test(rest))return "";' +
    'return rest;};' +
    'var AVATAR=/profile picture|头像|个人资料照片|个人资料图片/;' +
    'var links=document.querySelectorAll("a[href]");' +
    'var fallback="";' +
    'for(var i=0;i<links.length;i++){var link=links[i];' +
    'var href=String(link.getAttribute("href")||"");' +
    'if(!singleSeg(href))continue;' +
    'var img=link.querySelector("img[alt]");' +
    'var alt=img?String(img.getAttribute("alt")||"").toLowerCase():"";' +
    'if(AVATAR.test(alt))return href;' +
    'if(!fallback&&link.querySelector("img"))fallback=href;}' +
    'return fallback;}catch(e){return "";}})()';
/**
 * 在网页的当前信息流里按 shortcode 找到那条帖子的 article 节点。
 *
 * 点赞与评论都靠它定位 —— 两个脚本共用同一套查找逻辑（各自内联一份，因为注入脚本
 * 之间不共享作用域）。
 */
const FIND_ARTICLE_JS: string = 'var findArticle=function(){' +
    'var arts=document.querySelectorAll("main article");' +
    'for(var i=0;i<arts.length;i++){' +
    'var as=arts[i].querySelectorAll(\'a[href*="/p/"],a[href*="/reel/"],a[href*="/tv/"]\');' +
    'for(var j=0;j<as.length;j++){' +
    'var h=String(as[j].getAttribute("href")||"");' +
    'if(h.indexOf("/"+CODE+"/")>=0)return arts[i];}}' +
    'return null;};';
/** 注入脚本里用得到的等待工具。 */
const SLEEP_JS: string = 'var sleep=function(ms){return new Promise(function(r){setTimeout(r,ms);});};';
/**
 * 「在网页当前这条帖子上点某一条评论的赞」的脚本。
 *
 * 为什么要有它：评论点赞的 HTTP 那条路被 IG 用**客户端指纹**挡着
 * （`410 {"message":"useragent mismatch"}`，见 core/NativeComments.like），而网页自己点
 * 是不会被挡的 —— 和帖子点赞的兜底同一套路数（见 likePostScript）。
 * 附带好处：页面发过一次之后，那条请求就能被 `capture('comment')` 存成模板，
 * 下次原生回放就有了（自举）。
 *
 * 怎么找到"那一条评论"：IG 每条评论的**时间戳是一个链接**，href 里带这条评论的 id
 * （形如 `/p/{code}/c/{评论id}/`）—— 这是最稳的锚点（比按文案/序号找可靠得多）。
 * 从那个链接往上找**最近的**、含点赞按钮的那个容器（评论行），别升到整条帖子上去
 * （帖子自己也有一个点赞按钮，升上去就会点错）。
 *
 * @param commentPk 评论的数字 id。
 * @param like      true = 点赞，false = 取消赞。
 * 返回 state：liked / unliked / same（本来就是这个状态）/ not-found / no-button / error。
 */
export function likeCommentScript(commentPk: string, like: boolean): string {
    const pkLiteral: string = JSON.stringify(commentPk);
    return '(async function(){try{' +
        'var PK=' + pkLiteral + ';' +
        'var WANT=' + (like ? 'true' : 'false') + ';' +
        'var LIKED=/^(Unlike|取消赞|收回讚|いいねを取り消す)$/i;' +
        'var LIKE=/^(Like|赞|讚|いいね)$/i;' +
        SLEEP_JS +
        // 1) 按评论 id 找锚点（href 里带 /c/{pk}/）。
        'var as=document.querySelectorAll("a[href]");' +
        'var anchor=null;' +
        'for(var i=0;i<as.length;i++){' +
        'var h=String(as[i].getAttribute("href")||"");' +
        'if(h.indexOf("/c/"+PK+"/")>=0){anchor=as[i];break;}}' +
        'if(!anchor)return JSON.stringify({state:"not-found"});' +
        // 2) 往上找最近的含点赞按钮的容器（不越过 ARTICLE）。
        'var pick=function(scope){' +
        'if(!scope)return null;' +
        'var svgs=scope.querySelectorAll("svg[aria-label]");' +
        'for(var j=0;j<svgs.length;j++){' +
        'var l=String(svgs[j].getAttribute("aria-label")||"");' +
        'if(LIKED.test(l)||LIKE.test(l))return svgs[j];}' +
        'return null;};' +
        'var scope=anchor;var svg=null;' +
        'for(var up=0;up<8&&scope;up++){' +
        'if(String(scope.tagName||"").toUpperCase()==="ARTICLE")break;' +
        'var hit=pick(scope);' +
        'if(hit){svg=hit;break;}' +
        'scope=scope.parentElement;}' +
        'if(!svg)return JSON.stringify({state:"no-button"});' +
        // 3) 已经是想要的状态就不点（避免把"点赞"点成"取消赞"）。
        'var before=LIKED.test(String(svg.getAttribute("aria-label")||""));' +
        'if(before===WANT)return JSON.stringify({state:WANT?"liked":"unliked",same:true});' +
        'var target=svg.closest("button")||svg.closest(\'[role="button"]\')||svg.parentElement||svg;' +
        'try{target.click();}catch(e){' +
        'try{svg.dispatchEvent(new MouseEvent("click",{bubbles:true}));}' +
        'catch(e2){return JSON.stringify({state:"error",message:"click failed"});}}' +
        // 4) 等页面把 aria-label 翻过来（上限 1.2 秒，同 likePostScript）。
        'var deadline=Date.now()+1200;' +
        'while(Date.now()<deadline){' +
        'await sleep(80);' +
        'var now=LIKED.test(String(svg.getAttribute("aria-label")||""));' +
        'if(now!==before)return JSON.stringify({state:now?"liked":"unliked"});}' +
        'return JSON.stringify({state:WANT?"liked":"unliked",assumed:true});' +
        '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}

/**
 * 生成「在网页当前信息流里点一下某条帖子的点赞按钮」的脚本。
 *
 * 原生侧不构造任何请求：只是让网页去点它自己的点赞按钮，写操作由页面用它自己的
 * 会话与 csrf 完成，请求形状也由页面决定 —— 因此这里不依赖任何 Instagram 接口细节。
 *
 * **只认信息流里按 shortcode 找到的那条帖子**。找不到就返回 not-found，由原生侧
 * 改成「真的导航到该帖页面」再点（见 likeOnPostPageScript）—— 早先用 pushState 做
 * SPA 路由，URL 会立刻变但视图未必真的切过去，那个假前提会导致给**别的**帖子点赞。
 *
 * 返回 state：liked / unliked / not-found / no-button / error。
 */
export function likePostScript(shortcode: string): string {
    const codeLiteral: string = JSON.stringify(shortcode);
    return '(async function(){try{' +
        'var CODE=' + codeLiteral + ';' +
        // 点赞按钮的 aria-label：英文 / 简繁中文 / 日文都认。
        'var LIKED=/^(Unlike|取消赞|收回讚|いいねを取り消す)$/i;' +
        'var LIKE=/^(Like|赞|讚|いいね)$/i;' +
        FIND_ARTICLE_JS +
        SLEEP_JS +
        'var findSvg=function(scope){if(!scope)return null;' +
        'var svgs=scope.querySelectorAll("svg[aria-label]");' +
        'for(var i=0;i<svgs.length;i++){' +
        'var l=String(svgs[i].getAttribute("aria-label")||"");' +
        'if(LIKED.test(l)||LIKE.test(l))return svgs[i];}return null;};' +
        'var art=findArticle();' +
        'if(!art)return JSON.stringify({state:"not-found"});' +
        'var svg=findSvg(art);' +
        'if(!svg)return JSON.stringify({state:"no-button"});' +
        'var before=LIKED.test(String(svg.getAttribute("aria-label")||""));' +
        'var target=svg.closest("button")||svg.closest(\'[role="button"]\')||svg.parentElement||svg;' +
        'try{target.click();}catch(e){' +
        'try{svg.dispatchEvent(new MouseEvent("click",{bubbles:true}));}' +
        'catch(e2){return JSON.stringify({state:"error",message:"click failed"});}}' +
        // 页面会就地翻转 aria-label；等它真翻过来再回报。
        // 上限压到 1.2 秒、轮询 80ms：这是在桥上调用的，等得越久这一次点赞占用得越久。
        // 页面通常几百毫秒就翻过来了，等不到就按「取反」回报（下次刷新信息流会校正），
        // 不值得为了多确认一会儿让用户等。
        'var deadline=Date.now()+1200;' +
        'while(Date.now()<deadline){' +
        'await sleep(80);' +
        'var now=findSvg(svg.closest("article"));' +
        'if(now){var after=LIKED.test(String(now.getAttribute("aria-label")||""));' +
        'if(after!==before)return JSON.stringify({state:after?"liked":"unliked"});}}' +
        // 没等到翻转：点击已经发出去了，按「取反」回报；下次刷新信息流会校正。
        'return JSON.stringify({state:before?"unliked":"liked",assumed:true});' +
        '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}
/**
 * 生成「在网页当前信息流里点一下某条帖子的转发按钮」的脚本。
 *
 * 和点赞**同一套路数**（见 likePostScript）：转发和取消转发在网页上就是**同一个按钮**
 * （已转发状态下再点一次即取消，用户实机确认过），所以两边都只需要
 * 「读出现在是哪一边 → 点 → 等文案翻过去 → 回报新状态」。
 *
 * 三处踩过的坑，决定了这个脚本长这样：
 *   1) **找不到按钮**。最初只认 `svg[aria-label]` 且正则首尾锚定，结果已转发状态下
 *      文案里混进了图标自己的名字（`取消转发“图标”` 那种，关注按钮上实测过同一个毛病），
 *      整条匹配不上 → 退到菜单 → 什么都没找到 → 原生那边判成"没有转发入口"并把用户丢到
 *      帖子页（表现就是"取消失败了"）。所以现在：先洗文案（canon），再**宽松**匹配，
 *      而且依次在 svg / button / [role=button] 上找。
 *   2) **点错了控件**。实测日志：未转发时帖子里只有一个"转发"；转发成功后**帖子头部会多出
 *      一个同样叫"转发"的标记**（seen 从 `更多选项|赞|评论|转发|分享|收藏` 变成
 *      `更多选项|转发|赞|评论|转发|分享|收藏`），而它排在 DOM 前面。按"第一个命中的"去点，
 *      第二次点到的就是这个标记 —— 点了毫无反应，表现同样是"取消转发不生效"。
 *      所以现在取 DOM 里**最后一个**（动作区在正文之后），并用"同排还有赞/评论/分享"确认。
 *   3) **方向读不出来**。这个按钮的 aria-label 两个方向都叫"转发"（实测 `label=转发->转发`），
 *      文案指望不上。好在那个"已转发标记"是**真实的状态信号**：帖子里出现第二个"转发"文案
 *      就算已转发（见 stateOf）。真读不出来时才回报 assumed，由原生侧保留乐观翻转的结果。
 *
 * 找不到直接按钮时退回「更多」菜单里的同名条目（有些版本把转发收在菜单里）。
 * seen 每次都带上帖子里那排控件的文案（hilog 里能看到网页到底怎么命名），排查不用猜。
 * 返回 state：reposted / unreposted / assumed / not-found / no-button / error。
 */
export function repostPostScript(shortcode: string): string {
    const codeLiteral: string = JSON.stringify(shortcode);
    return '(async function(){try{' +
        'var CODE=' + codeLiteral + ';' +
        // 「已转发那一侧」的文案：动作派（取消转发 / Undo repost）和状态派（已转发 / Reposted）
        // 都要认。**不做首尾锚定** —— 文案尾巴上常挂别的东西（见上面第 1 条）。
        'var DONE=/取消转发|取消轉發|已转发|已轉發|收回转发|undo repost|unrepost|reposted|リポスト済み|リポストを取り消/i;' +
        // 「还没转发那一侧」。
        'var REPOST=/转发|轉發|repost|リポスト/i;' +
        // 「更多」菜单的入口。
        'var MORE=/more options|更多选项|更多|その他/i;' +
        FIND_ARTICLE_JS +
        SLEEP_JS +
        // 洗文案：去掉引号里的图标名与"图标"两个字（同 FOLLOW_BUTTON_JS 的 canon）。
        'var canon=function(v){var s=String(v==null?"":v).replace(/\\s+/g," ").trim();' +
        's=s.replace(/[“”"\'‘’][^“”"\'‘’]{0,24}[“”"\'‘’]图标/g,"");' +
        's=s.replace(/图标/g,"");' +
        'return s.replace(/\\s+/g," ").trim();};' +
        'var cleanLabel=function(n){' +
        'try{return canon(n&&n.getAttribute?n.getAttribute("aria-label"):"");}catch(e){return "";}};' +
        'var innermost=function(n){if(!n||n.tagName==="BUTTON")return n;' +
        'try{var b=n.querySelector(\'button,[role="button"]\');if(b&&b!==n)return innermost(b);}catch(e){}return n;};' +
        // 真正带点击处理的往往是最里层那颗 button：先从 svg 往上找最近的 button/[role=button]，
        // 再往下钻到最里层那颗（外层有时只是个壳），最后把指针事件补齐（见上面第 2 条）。
        'var pointerAt=function(t,el,cx,cy){' +
        'try{return new PointerEvent(t,{bubbles:true,cancelable:true,composed:true,' +
        'pointerId:1,pointerType:"touch",isPrimary:true,width:1,height:1,pressure:0.5,' +
        'button:0,buttons:t==="pointerdown"?1:0,clientX:cx,clientY:cy});}catch(e){return null;}};' +
        'var fireClick=function(n){var el=n;' +
        'try{el=(n.closest&&(n.closest("button")||n.closest(\'[role="button"]\')))||n.parentElement||n;}catch(e){el=n;}' +
        'el=innermost(el)||el;var r=null;' +
        'try{r=el.getBoundingClientRect();}catch(e){}' +
        'var cx=r?Math.round(r.left+r.width/2):0;var cy=r?Math.round(r.top+r.height/2):0;' +
        'var order=["pointerover","pointerenter","pointerdown","pointerup"];' +
        'for(var i=0;i<order.length;i++){var pe=pointerAt(order[i],el,cx,cy);if(pe){try{el.dispatchEvent(pe);}catch(e){}}}' +
        'try{el.click();return true;}catch(e2){}' +
        'try{el.dispatchEvent(new MouseEvent("click",{bubbles:true,cancelable:true,view:window}));return true;}' +
        'catch(e3){return false;}};' +
        // 帖子里所有「转发 / 已转发」文案的控件，顺序就是 DOM 顺序。
        'var candsOf=function(scope){var out=[];if(!scope)return out;' +
        'var ns=scope.querySelectorAll("svg[aria-label],button[aria-label],[role=button][aria-label]");' +
        'for(var i=0;i<ns.length;i++){var l=cleanLabel(ns[i]);' +
        'if(REPOST.test(l)||DONE.test(l))out.push(ns[i]);}return out;};' +
        // 动作区那一排的邻居文案：用来确认"这个控件确实在动作区里"。
        'var MATE=/^(赞|讚|Like|评论|評論|Comment|分享|Share|收藏|保存|Save|转发|轉發|Repost|リポスト)/i;' +
        'var hasActionMate=function(n){' +
        'try{var p=n.parentElement;' +
        'for(var up=0;up<2&&p;up++){' +
        'var ns=p.querySelectorAll("svg[aria-label],button[aria-label],[role=button][aria-label]");' +
        'var c=0;for(var i=0;i<ns.length;i++){var l=cleanLabel(ns[i]);if(l.length>0&&MATE.test(l))c++;}' +
        'if(c>=2)return true;p=p.parentElement;}' +
        '}catch(e){}return false;};' +
        // 要点的必须是**动作区那一颗**。
        //
        // 实测（日志 seen=更多选项|赞|评论|转发|分享|收藏）：未转发时帖子里只有一个"转发"；
        // 转发成功后帖子**头部多出一个同样叫"转发"的标记**（seen 变成 更多选项|转发|赞|评论|转发|分享|收藏），
        // 而它在 DOM 里排在前面 —— 按"第一个命中的"去点就会点到这个标记上，点了毫无反应，
        // 表现就是"取消转发不生效"。所以这里取 **DOM 里最后一个**（动作区在正文之后），
        // 再用"同一排里还有赞/评论/分享"兜一道确认。
        'var pickAction=function(scope){var cs=candsOf(scope);if(cs.length===0)return null;' +
        'var best=null;for(var i=0;i<cs.length;i++){if(hasActionMate(cs[i]))best=cs[i];}' +
        'return best||cs[cs.length-1];};' +
        // 当前状态：出现**第二个**"转发"文案（那个标记）就算已转发；否则看文案本身。
        'var countReposts=function(scope){return candsOf(scope).length;};' +
        'var stateOf=function(scope,label){return countReposts(scope)>=2||DONE.test(label);};' +
        // 诊断用：把每个"转发"候选描述出来（标签/role/class/在不在动作区），
        // 这样一眼能看出多出来那个到底是"已转发标记"、弹层菜单项还是提示条。
        'var descOf=function(n){' +
        'try{return String(n.tagName||"")+"/"+String(n.getAttribute("role")||"")+"/"+' +
        'String(n.getAttribute("class")||"").slice(0,22)+"/m"+(hasActionMate(n)?"1":"0");}' +
        'catch(e){return "?";}};' +
        // 诊断用：页面上有没有 toast / 状态条（有的流程是弹一条"已转发 / 撤销"）。
        'var tf=function(){try{var t=document.querySelector(\'[role="status"],[role="alert"]\');' +
        'return t?canon(String(t.textContent||"")).slice(0,50):"";}catch(e){return "";}};' +
        'var art=findArticle();' +
        'if(!art)return JSON.stringify({state:"not-found"});' +
        // 诊断：帖子那排控件的文案原样带回去，网页用哪套命名一眼可见。
        'var all=art.querySelectorAll("svg[aria-label],button[aria-label],[role=button][aria-label]");' +
        'var seen=[];' +
        'for(var s=0;s<all.length&&seen.length<14;s++){var sl=cleanLabel(all[s]);if(sl.length>0)seen.push(sl);}' +
        'var btn=pickAction(art);' +
        'if(btn){' +
        'var lb=cleanLabel(btn);' +
        'var cnt=countReposts(art);' +
        'var before=stateOf(art,lb);' +
        'var desc=[];var cs0=candsOf(art);' +
        'for(var d=0;d<cs0.length&&d<4;d++){desc.push(descOf(cs0[d]));}' +
        'fireClick(btn);' +
        // 等页面把状态翻过去再回报。这里给到 2.5 秒（点赞只要翻文案，用得少）：
        // 实测取消转发后那个"已转发标记"不一定像出现时那么快消失，可能要等服务端确认。
        'var deadline=Date.now()+2500;' +
        'while(Date.now()<deadline){' +
        'await sleep(80);' +
        'var scope=btn.closest("article")||art;' +
        'var now=pickAction(scope);' +
        'var nl=now?cleanLabel(now):"";' +
        'var after=stateOf(scope,nl);' +
        'if(after!==before)return JSON.stringify({state:after?"reposted":"unreposted",via:"button",' +
        'label:lb,labelAfter:nl,cnt:cnt,cands:desc.join(" || "),toast:tf(),seen:seen.join("|")});}' +
        'var scope2=btn.closest("article")||art;' +
        'var last=pickAction(scope2);' +
        'return JSON.stringify({state:"assumed",via:"button",label:lb,' +
        'labelAfter:last?cleanLabel(last):"",cnt:cnt,cands:desc.join(" || "),toast:tf(),' +
        'seen:seen.join("|")});}' +
        // 兜底：帖子「更多」菜单里的同名条目。
        'var more=null;' +
        'for(var m=0;m<all.length;m++){if(MORE.test(cleanLabel(all[m]))){more=all[m];break;}}' +
        'if(!more)return JSON.stringify({state:"no-button",seen:seen.join("|")});' +
        'fireClick(more);' +
        'await sleep(700);' +
        'var items=document.querySelectorAll(\'[role="menuitem"],[role="button"],button\');' +
        'var hit=null;var hitText="";' +
        'for(var k=0;k<items.length;k++){' +
        'var t=canon(String(items[k].textContent||""));if(t.length===0)t=cleanLabel(items[k]);' +
        // 菜单项文字都很短；放宽了容易命中正文里出现 repost 字样的普通节点。
        'if(t.length>40)continue;' +
        'if(REPOST.test(t)||DONE.test(t)){hit=items[k];hitText=t;break;}}' +
        'if(hit){' +
        'fireClick(hit);await sleep(600);' +
        // 菜单文案同样读不出方向（菜单项写的多半是"动作"），一样交回 assumed。
        'return JSON.stringify({state:"assumed",via:"menu",label:hitText,labelAfter:"",seen:seen.join("|")});}' +
        // 菜单开着但没命中：按 Escape 收回，别把页面留在菜单展开的状态。
        'try{document.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",keyCode:27,bubbles:true}));}catch(e){}' +
        'return JSON.stringify({state:"no-button",seen:seen.join("|")});' +
        '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}
/**
 * 找对方主页头部那颗关注按钮（下面的三段脚本共用）。
 *
 * - 按 header → main 里的 section → 整页 的顺序找：整页扫描会先撞上侧栏/底部的
 *   "为你推荐"，那儿的按钮也是"关注"，点错就是关注了一个不相关的人。
 * - 未关注时文案是「关注/回关/Follow」，已关注时是「已关注/关注中/Following」。
 */
const FOLLOW_BUTTON_JS: string = 'var OFF=/^(关注|回关|Follow|Follow back|フォロー)$/i;' +
    'var ON=/^(已关注|关注中|Following|Requested|フォロー中)$/i;' +
    'var clean=function(v){return String(v==null?"":v).replace(/\\s+/g," ").trim();};' +
    // 按钮的 textContent 里还带着**图标自己的无障碍文案**：已关注之后按钮变成
    // `已关注“向下箭头”图标`（实测），直接和"已关注"比会整个不匹配，表现就是
    // "点了关注之后反而找不到按钮/读不出已关注"。所以先把引号里的图标名和"图标"去掉。
    'var canon=function(v){var s=clean(v);' +
    's=s.replace(/[“”"\'‘’][^“”"\'‘’]{0,24}[“”"\'‘’]图标/g,"");' +
    's=s.replace(/图标/g,"");' +
    'return s.replace(/\\s+/g," ").trim();};' +
    // 再只取**开头那个关键词**（关注 / 回关 / 已关注 / 关注中 …）当按钮文案：
    // 这样后面无论再挂什么尾巴都不影响判定，也不用写一堆"允许尾部垃圾"的正则。
    // 注意顺序：先把"已关注/关注中"这类**已关注态**认掉，再去认"关注/回关"。
    'var canonLabel=function(v){var s=canon(v);' +
    'var m1=s.match(/^(已关注|关注中|已请求|Following|Requested|フォロー中)/i);if(m1)return m1[0];' +
    'var m2=s.match(/^(回关|Follow back|关注|Follow|フォロー)/i);if(m2)return m2[0];' +
    'return s;};' +
    'var labelOf=function(n){' +
    'try{var t=canonLabel(n.textContent);if(t.length===0)t=canonLabel(n.getAttribute&&n.getAttribute("aria-label"));' +
    'return t;}catch(e){return "";}};' +
    'var clickable=function(n){return n.closest("button")||n.closest(\'[role="button"]\')||n;};' +
    // 真正带点击处理的往往是**最里层那颗 button**：外层 [role=button] 有时只是个壳，
    // 点壳子对"关注"能生效、对"取消关注"却不弹菜单（实测点了之后菜单一直找不到）。
    'var innermost=function(n){if(!n||n.tagName==="BUTTON")return n;' +
    'try{var b=n.querySelector(\'button,[role="button"]\');if(b&&b!==n)return innermost(b);}catch(e){}' +
    'return n;};' +
    // 只发一个 click 事件对多数按钮够用，但保险起见把指针那套也补上：
    // 有些组件挂在 pointerdown 上，只发 click 它不认。用**真的 PointerEvent**
    // （不是换个 type 名的 MouseEvent），React 的指针事件才认。
    'var pointerAt=function(t,target,cx,cy){' +
    'try{return new PointerEvent(t,{bubbles:true,cancelable:true,composed:true,' +
    'pointerId:1,pointerType:"touch",isPrimary:true,width:1,height:1,pressure:0.5,' +
    'button:0,buttons:t==="pointerdown"?1:0,clientX:cx,clientY:cy});}catch(e){return null;}};' +
    'var fireClick=function(n){var el=innermost(n)||n;' +
    'var r=null;try{r=el.getBoundingClientRect();}catch(e){}' +
    'var cx=r?Math.round(r.left+r.width/2):0;var cy=r?Math.round(r.top+r.height/2):0;' +
    'try{el.scrollIntoView({block:"center"});r=el.getBoundingClientRect();' +
    'cx=Math.round(r.left+r.width/2);cy=Math.round(r.top+r.height/2);}catch(e){}' +
    'var order=["pointerover","pointerenter","pointerdown","pointerup"];' +
    'for(var i=0;i<order.length;i++){' +
    'var pe=pointerAt(order[i],el,cx,cy);if(pe){try{el.dispatchEvent(pe);}catch(e){}}}' +
    'try{el.click();return true;}catch(e2){}' +
    'try{el.dispatchEvent(new MouseEvent("click",{bubbles:true,cancelable:true,view:window}));return true;}' +
    'catch(e3){return false;}};' +
    'var tagOf=function(n){try{var el=innermost(n)||n;' +
    'return String(el.tagName||"")+"/"+String(el.getAttribute("role")||"")+"/"+String(el.className||"").slice(0,40);}' +
    'catch(e){return "";}};' +
    'var scan=function(scope){' +
    'if(!scope)return null;' +
    'var btns=scope.querySelectorAll(\'button,div[role="button"]\');' +
    'for(var i=0;i<btns.length;i++){' +
    'var t=labelOf(btns[i]);' +
    'if(OFF.test(t)||ON.test(t))return {node:btns[i],label:t};}' +
    'return null;};' +
    'var pick=function(){' +
    'var hit=scan(document.querySelector("header"));if(hit)return hit;' +
    'var main=document.querySelector("main");' +
    'if(main){var secs=main.querySelectorAll("section");' +
    'for(var s=0;s<secs.length;s++){hit=scan(secs[s]);if(hit)return hit;}}' +
    'return scan(document);};' +
    // 排查用：把页面上看得见的按钮文案捞几条出来（按钮找不到时能看出页面到底长什么样）。
    'var seenLabels=function(){var out=[];' +
    'var bs=document.querySelectorAll(\'button,div[role="button"]\');' +
    'for(var i=0;i<bs.length&&out.length<8;i++){' +
    'var t=labelOf(bs[i]);if(t.length>0&&t.length<=24)out.push(t);}' +
    'return out.join("|");};' +
    'var herePath=function(){' +
    'return String(location.pathname||"").replace(/^\\//,"").replace(/\\/$/,"");};';
/**
 * 读一次对方主页头部的关注状态（只读，不点任何东西）。
 *
 * **刻意写成短脚本**：里面一次 await 都没有。主页脚本里长时间 await 很容易因为页面
 * 自己的一次重载/路由跳转，把执行上下文连同回调一起丢掉，原生那边就只能等到超时
 * （实测就是这么挂的，脚本跑了满 20 秒没有任何回报）。
 * 所以「等按钮渲染出来」改由原生侧轮询，这里只负责看一眼当前是什么。
 *
 * 返回 state：ok / no-button / error，附带 path（URL 里的人名）和 seen（页面上按钮文案样本）。
 */
export function followStateScript(username: string): string {
    const nameLiteral: string = JSON.stringify(username);
    return '(function(){try{' +
        'var NAME=' + nameLiteral + ';' +
        FOLLOW_BUTTON_JS +
        'var path=herePath();' +
        'var hit=pick();' +
        'return JSON.stringify({state:hit?"ok":"no-button",path:path,label:hit?hit.label:"",' +
        'following:hit?ON.test(hit.label):false,seen:seenLabels()});' +
        '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}
/**
 * 点一下对方主页头部的关注按钮（原生侧已经真的导航到了该用户主页）。
 *
 * 和点赞同一套思路：不构造任何请求，只是让网页去点它自己的按钮，写操作由页面用它
 * 自己的会话与 csrf 完成。**同样不做长等待**：点完立刻回报，等页面确认交给原生侧。
 *
 * 只做关注这一个方向 —— 反方向（点「已关注」取关）在网页侧要点一个二次确认菜单，
 * 而那个菜单只认真实用户的触摸手势，脚本点不开（实测：怎么合成点击都不弹，
 * 整页文字里根本没有"取消关注"）。所以调用方也只会拿它来关注。
 *
 * 返回 state：clicked / already（本来就是已关注）/ no-button / wrong-page / error。
 */
export function followClickScript(username: string): string {
    const nameLiteral: string = JSON.stringify(username);
    return '(function(){try{' +
        'var NAME=' + nameLiteral + ';' +
        FOLLOW_BUTTON_JS +
        // URL 必须是这个人的主页，否则不动手（读状态那支不点东西，所以这道闸放在这里）。
        'var path=herePath();' +
        'if(path.toLowerCase()!==NAME.toLowerCase()){' +
        'return JSON.stringify({state:"wrong-page",path:path});}' +
        'var hit=pick();' +
        'if(!hit)return JSON.stringify({state:"no-button",path:path,seen:seenLabels()});' +
        'var before=hit.label;' +
        'if(ON.test(before))return JSON.stringify({state:"already",before:before,path:path});' +
        'var ok=fireClick(hit.node);' +
        'if(!ok)return JSON.stringify({state:"error",message:"click failed"});' +
        'return JSON.stringify({state:"clicked",before:before,path:path,node:tagOf(hit.node)});' +
        '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}
/**
 * 生成「在帖子 / Reels 页面上点一下**收藏（书签）**按钮」的脚本。
 *
 * 需求："reels 页面添加收藏按钮……收藏按钮实现一下功能，用 http 请求"。
 * 原生那一条路是 `POST i.instagram.com/api/v1/media/{id}/save|unsave/`（core/NativeSave），
 * 但那个路由**要 App 身份的会话**，我们手上只有网页会话 —— 真机实测回的是
 * `{"status":"fail"}`（见 NativeSave 的文件头）。所以失败之后退回这里：
 * **让页面用它自己的会话与 csrf 去点它自己的书签按钮**，和点赞 / 转发那条老路一模一样。
 *
 * 安全底线同点赞脚本：先确认 URL 里确实是这条 shortcode，再动手；只在能唯一确定是主帖的
 * 那个书签按钮时才点（`main article` 里的第一个；找不到就要求"全页只有一个"）。
 *
 * IG 网页上这颗按钮的 `aria-label`：未收藏 = `Save`，已收藏 = `Remove`
 * （多语言下也可能是「收藏 / 取消收藏」这类文案，所以两边都用正则）。
 *
 * @param shortcode 目标帖子 / Reels 的短码（导航用的那条）。
 * @param want      true = 要收藏，false = 要取消收藏。已经是目标状态就直接返回 ok。
 */
export function saveOnPostPageScript(shortcode: string, want: boolean): string {
    const codeLiteral: string = JSON.stringify(shortcode);
    return '(async function(){try{' +
        'var CODE=' + codeLiteral + ';' +
        'var WANT=' + (want ? 'true' : 'false') + ';' +
        'var SAVED=/^(Remove|Unsave|Saved|取消收藏|收回收藏|已收藏|移除|削除)$/i;' +
        'var SAVE=/^(Save|收藏|儲存|保存|保存する)$/i;' +
        SLEEP_JS +
        'var labelOf=function(svg){return String(svg.getAttribute("aria-label")||"");};' +
        // 两个正则都是**整串匹配**（^…$）：中文里"取消收藏"包含"收藏"，
        // 不锚定的话两个都会命中，方向就判不出来了。
        'var isSaved=function(svg){return SAVED.test(labelOf(svg));};' +
        'var findSvg=function(scope){if(!scope)return null;' +
        'var svgs=scope.querySelectorAll("svg[aria-label]");' +
        'for(var i=0;i<svgs.length;i++){' +
        'var l=labelOf(svgs[i]);' +
        'if(SAVED.test(l)||SAVE.test(l))return svgs[i];}return null;};' +
        'var pickSvg=function(){' +
        'var inFirst=findSvg(document.querySelector("main article"));' +
        'if(inFirst)return inFirst;' +
        'var all=document.querySelectorAll("svg[aria-label]");var hits=[];' +
        'for(var i=0;i<all.length;i++){' +
        'var l=labelOf(all[i]);' +
        'if(SAVED.test(l)||SAVE.test(l))hits.push(all[i]);}' +
        'return hits.length===1?hits[0]:null;};' +
        'if(String(location.pathname||"").indexOf(CODE)<0){' +
        'return JSON.stringify({state:"not-found",reason:"off-post-page"});}' +
        // 等详情页把书签按钮渲染出来。
        'var dl=Date.now()+8000;var svg=null;' +
        'while(Date.now()<dl){svg=pickSvg();if(svg)break;await sleep(250);}' +
        'if(!svg)return JSON.stringify({state:"no-button"});' +
        'var before=isSaved(svg);' +
        'if(before===WANT)return JSON.stringify({state:"ok",already:true,saved:before});' +
        'var target=svg.closest("button")||svg.closest(\'[role="button"]\')||svg.parentElement||svg;' +
        'try{target.click();}catch(e){' +
        'try{svg.dispatchEvent(new MouseEvent("click",{bubbles:true}));}' +
        'catch(e2){return JSON.stringify({state:"error",message:"click failed"});}}' +
        'var deadline=Date.now()+3000;' +
        'while(Date.now()<deadline){' +
        'await sleep(150);' +
        'var now=pickSvg();' +
        'if(now){var after=isSaved(now);' +
        'if(after===WANT)return JSON.stringify({state:"ok",saved:after});}}' +
        // 文案没翻（有的版本两个方向共用一套文案）：保留这次点击的结果，别把用户刚做的操作弹回去。
        'return JSON.stringify({state:"ok",assumed:true,saved:WANT});' +
        '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}
/**
 * 生成「在帖子页面上点一下点赞按钮」的脚本（原生侧已经真的导航到了该帖页面）。
 *
 * 安全底线：先确认 URL 里确实是这条 shortcode，再动手；**并且只在能唯一确定是主帖的
 * 那个点赞按钮时才点** —— 帖子页下面常挂着相关推荐，点错就是给别的帖子点赞。
 * 判据是「第一个 main article 里的按钮」；找不到时只有全页仅一个点赞按钮才敢用。
 */
export function likeOnPostPageScript(shortcode: string): string {
    const codeLiteral: string = JSON.stringify(shortcode);
    return '(async function(){try{' +
        'var CODE=' + codeLiteral + ';' +
        'var LIKED=/^(Unlike|取消赞|收回讚|いいねを取り消す)$/i;' +
        'var LIKE=/^(Like|赞|讚|いいね)$/i;' +
        SLEEP_JS +
        'var findSvg=function(scope){if(!scope)return null;' +
        'var svgs=scope.querySelectorAll("svg[aria-label]");' +
        'for(var i=0;i<svgs.length;i++){' +
        'var l=String(svgs[i].getAttribute("aria-label")||"");' +
        'if(LIKED.test(l)||LIKE.test(l))return svgs[i];}return null;};' +
        'var pickSvg=function(){' +
        'var inFirst=findSvg(document.querySelector("main article"));' +
        'if(inFirst)return inFirst;' +
        'var all=document.querySelectorAll("svg[aria-label]");var hits=[];' +
        'for(var i=0;i<all.length;i++){' +
        'var l=String(all[i].getAttribute("aria-label")||"");' +
        'if(LIKED.test(l)||LIKE.test(l))hits.push(all[i]);}' +
        'return hits.length===1?hits[0]:null;};' +
        'if(String(location.pathname||"").indexOf(CODE)<0){' +
        'return JSON.stringify({state:"not-found",reason:"off-post-page"});}' +
        // 等详情页把点赞按钮渲染出来。
        'var dl=Date.now()+8000;var svg=null;' +
        'while(Date.now()<dl){svg=pickSvg();if(svg)break;await sleep(250);}' +
        'if(!svg)return JSON.stringify({state:"no-button"});' +
        'var before=LIKED.test(String(svg.getAttribute("aria-label")||""));' +
        'var target=svg.closest("button")||svg.closest(\'[role="button"]\')||svg.parentElement||svg;' +
        'try{target.click();}catch(e){' +
        'try{svg.dispatchEvent(new MouseEvent("click",{bubbles:true}));}' +
        'catch(e2){return JSON.stringify({state:"error",message:"click failed"});}}' +
        'var deadline=Date.now()+2500;' +
        'while(Date.now()<deadline){' +
        'await sleep(150);' +
        'var now=pickSvg();' +
        'if(now){var after=LIKED.test(String(now.getAttribute("aria-label")||""));' +
        'if(after!==before)return JSON.stringify({state:after?"liked":"unliked"});}}' +
        'return JSON.stringify({state:before?"unliked":"liked",assumed:true});' +
        '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}
/**
 * 从**页面自己的数据**里读评论（第二代实现）。
 *
 * 为什么不再扫 DOM：上一版是「找用户名链接 + 猜哪一层是列表」，实测经常选错容器 ——
 * 一次真实回报是 `plinks=20 bestN=3 first=instagram / 和 / muse / 为你推荐`，
 * 也就是把侧栏的"为你推荐"当成了评论列表。IG 的 DOM 是虚拟化且随时会变的，靠猜结构
 * 必然时好时坏。
 *
 * 现在改读页面**自己发过的那个评论请求**：
 *   1) 页面发评论请求时，NETWORK_WATCHER 把它原样存进 `window.__ogCommentCfg`
 *      （URL、方法、原始请求头、完整请求体）；
 *   2) 这里把它**原样回放**一次（只把 `variables.first` 调大到 50，尽量一次拿全），
 *      用页面自己的会话与 csrf，和它自己发的那个请求一模一样；
 *   3) 响应是结构化 JSON：只走进**键名里带 comment** 的分支，收集形如
 *      `{user:{username}, text}` 的节点 —— 用户名、正文、头像、点赞数都在里面，
 *      不用再猜 DOM；
 *   4) 回放拿不到时，退回页面内嵌的 JSON（`<script type="application/json">`）。
 *
 * 每条产出 {username, text, avatar, likes}。
 */
const COMMENTS_JSON_JS: string =
    // 预算常量：内嵌 JSON 兜底与深度遍历都封顶（理由见 collectEmbedded / collectInto 的说明）。
    'var MAX_EMBED_SCRIPTS=6;var MAX_EMBED_BYTES=400000;var MAX_EMBED_MS=2500;' +
    'var MAX_WALK_NODES=20000;var MAX_WALK_MS=2500;' +
// 1) 找页面刚发过的评论请求配置（回放用；多数时候用不上，响应已经存在 __ogCommentResps 里）。
'var findCommentCfg=function(){var c=window.__ogCommentCfg||null;if(c)return c;' +
    'var rep=window.__ogReplay||{};var ks=Object.keys(rep);' +
    'for(var i=0;i<ks.length;i++){if(/comment/i.test(ks[i]))return rep[ks[i]];}' +
    'return null;};' +
    // 2) 回放前把 first 调大：默认一页只有 10~20 条。
    'var bumpFirst=function(body,n){try{' +
    'var parts=String(body||"").split("&");' +
    'for(var i=0;i<parts.length;i++){' +
    'if(parts[i].indexOf("variables=")!==0)continue;' +
    'var obj=JSON.parse(decodeURIComponent(parts[i].substring(10)));' +
    'if(!obj||typeof obj!=="object")return body;' +
    'if(obj.first!==undefined)obj.first=n;' +
    'if(obj.data&&obj.data.first!==undefined)obj.data.first=n;' +
    'parts[i]="variables="+encodeURIComponent(JSON.stringify(obj));' +
    'return parts.join("&");}}catch(e){}return body;};' +
    // 3) 只认「键名里带 comment」的分支，进去之后整棵子树都看，收集评论节点 ——
    //    既不会把配文/推荐位收进来，也不用猜外层结构。
    //    out/seen 由调用方给，多个来源（页面响应 / 回放 / 内嵌 JSON）可以一起去重；
    //    keys 是命中的键名，排查时一眼就能看出结构对不对。
    'var collectInto=function(root,out,seen,keys){' +
    'var walkStart=Date.now();var walkN=0;' +
    // 预算：IG 的脚本/数据里有巨型对象，深度遍历不封顶就会把主线程钉住（实测桥超时）。
    // 走不完就少读几条，绝不把桥挂死 —— 调用方拿到的是"这次的快照"，下次还会再读。
    'var overBudget=function(){if(walkN>MAX_WALK_NODES)return true;' +
    'return (Date.now()-walkStart)>MAX_WALK_MS;};' +
    'var push=function(o){' +
    'if(!o||typeof o!=="object")return;' +
    'var u=(o.user&&typeof o.user==="object")?o.user:((o.owner&&typeof o.owner==="object")?o.owner:null);' +
    'if(!u)return;' +
    'var name=String(u.username||"");if(!name)return;' +
    'var text=(typeof o.text==="string")?o.text:"";' +
    'if(!text)return;' +
    'var key=name+"|"+text;if(seen[key])return;seen[key]=1;' +
    'var likes=0;' +
    'if(typeof o.comment_like_count==="number")likes=o.comment_like_count;' +
    'else if(typeof o.like_count==="number")likes=o.like_count;' +
    'var av=String(u.profile_pic_url||u.profile_pic_url_hd||"");' +
    'out.push({username:name,text:text,avatar:av,likes:likes});};' +
    'var deep=function(node,depth){' +
    'if(!node||depth>12)return;' +
    'if(++walkN>MAX_WALK_NODES)return;' +
    'if((walkN%512)===0&&overBudget())return;' +
    'if(Object.prototype.toString.call(node)==="[object Array]"){' +
    'for(var i=0;i<node.length;i++)deep(node[i],depth+1);return;}' +
    'if(typeof node!=="object")return;' +
    'push(node);' +
    'var ks=Object.keys(node);' +
    'for(var k=0;k<ks.length;k++){var v=node[ks[k]];' +
    'if(v&&typeof v==="object")deep(v,depth+1);}};' +
    'var scan=function(node,depth){' +
    'if(!node||depth>12)return;' +
    'if(++walkN>MAX_WALK_NODES)return;' +
    'if((walkN%512)===0&&overBudget())return;' +
    'if(Object.prototype.toString.call(node)==="[object Array]"){' +
    'for(var i=0;i<node.length;i++)scan(node[i],depth+1);return;}' +
    'if(typeof node!=="object")return;' +
    'var ks=Object.keys(node);' +
    'for(var k=0;k<ks.length;k++){var key=ks[k];var v=node[key];' +
    'if(!v||typeof v!=="object")continue;' +
    'if(/comment/i.test(key)){' +
    'if(keys&&keys.length<8&&keys.indexOf(key)<0)keys.push(key);' +
    'deep(v,0);}else scan(v,depth+1);}};' +
    'scan(root,0);};' +
    // 4) 兜底：页面内嵌的 JSON（帖子页首屏会把前几条评论一起塞进来）。
    //    逐个试**所有**带 comment 的脚本：只挑第一个会挑到只有 comments_disabled 那种，
    //    于是明明页面里有评论却读成空。
    //
    //    **必须掐预算**（实测教训）：这一步原来是"凡是含 comment 的 script 就 JSON.parse +
    //    12 层递归深走"，可 IG 页面里有 180KB / 98KB 的 **JS bundle** 也带 comment 字样
    //    （键名是 require，那是代码不是数据）。那样走下来说脚本几十秒都回不来，桥直接超时，
    //    表现就是 `state=timeout` —— 实测连轻量探针都被这个拖到 12 秒超时过。
    //    所以：只认"看起来是数据"的脚本（type 含 json 且以 `{` 开头）、单个体积与总数封顶、
    //    深走另给节点/时间预算（见 collectInto）。宁可少读几条，也不能把桥挂死。
    'var collectEmbedded=function(out,seen,keys){var n0=out.length;var t0=Date.now();var tried=0;try{' +
    'var ss=document.querySelectorAll(\'script[type="application/json"]\');' +
    'for(var i=0;i<ss.length;i++){' +
    'if(tried>=MAX_EMBED_SCRIPTS||Date.now()-t0>MAX_EMBED_MS)break;' +
    'var t=String(ss[i].textContent||"");' +
    'if(t.length===0||t.length>MAX_EMBED_BYTES)continue;' +
    'if(t.charAt(0)!=="{")continue;' +
    'if(!/comment/i.test(t))continue;' +
    'tried++;' +
    'try{var j=JSON.parse(t);if(j)collectInto(j,out,seen,keys);}catch(e){}}}catch(e){}' +
    'return out.length-n0;};' +
    // 5) 读一次，按可靠性从高到低试三条路：
    //    a) 页面自己**已经收到的响应**（原样，不额外请求，最可靠）；
    //    b) 原样回放页面发过的那个评论请求（能一次多要一些）；
    //    c) 页面内嵌的 JSON。
    'var readCommentsJson=async function(timeoutMs,onTick){' +
    'var t0=Date.now();var dl=t0+timeoutMs;' +
    'while(Date.now()<dl){' +
    'if(window.__ogCommentResps&&window.__ogCommentResps.length>0)break;' +
    'if(findCommentCfg())break;' +
    'if(onTick){try{onTick();}catch(e){}}' +
    'await sleep(250);}' +
    'var wait=Date.now()-t0;' +
    'var out=[];var seen={};var keys=[];var src="none";var http=0;' +
    'var resps=window.__ogCommentResps||[];' +
    'for(var r=0;r<resps.length;r++){' +
    'try{var rj=JSON.parse(resps[r]);if(rj)collectInto(rj,out,seen,keys);}catch(e){src="resp-nonjson";}}' +
    'if(out.length>0)src="resp";' +
    'var cfg=findCommentCfg();' +
    'var cfgName=cfg?String(cfg.n||cfg.u||"").slice(0,48):"-";' +
    'var replayMs=0;' +
    'if(out.length===0&&cfg){' +
    'var t1=Date.now();' +
    'var headers={};var hs=cfg.h||[];' +
    'for(var h=0;h<hs.length;h++){headers[hs[h][0]]=hs[h][1];}' +
    'var body=bumpFirst(String(cfg.b||""),50);' +
    'body=body.replace(/__req=[^&]*/,"__req="+Math.random().toString(36).slice(2,4));' +
    'try{var ac=new AbortController();var tm=setTimeout(function(){ac.abort();},6000);' +
    'var res=await fetch(String(cfg.u||""),{method:String(cfg.m||"POST"),credentials:"include",' +
    'headers:headers,body:(body.length>0?body:undefined),signal:ac.signal});' +
    'clearTimeout(tm);' +
    'if(res){http=res.status;var txt=await res.text();var json=null;' +
    'try{json=JSON.parse(txt);}catch(e){}' +
    'if(json){collectInto(json,out,seen,keys);src="replay";}else{src="replay-nonjson";}}}' +
    'catch(e){src="replay-error";}' +
    'replayMs=Date.now()-t1;}' +
    'if(out.length===0){if(collectEmbedded(out,seen,keys)>0)src=src+"/embedded";else src=src+"/embedded-empty";}' +
    'return {items:out,diag:"src="+src+" resps="+resps.length+" http="+http+" wait="+wait' +
    '+" replay="+replayMs+" cfg="+cfgName+" n="+out.length+" keys="+keys.slice(0,4).join("|")};};' +
    // 评论按钮（评论区的入口）。在帖子页上点它**不会导航走**，页面却一定会去请求评论。
    'var findCommentBtn=function(){' +
    'var scope=document.querySelector("main article")||document.querySelector("main")||document;' +
    'var cands=scope.querySelectorAll("svg[aria-label],button[aria-label],[role=button][aria-label]");' +
    'for(var i=0;i<cands.length;i++){' +
    'var l=String(cands[i].getAttribute("aria-label")||"");' +
    'if(/评论|Comment/i.test(l)){' +
    'return cands[i].closest("button")||cands[i].closest(\'[role="button"]\')||cands[i];}}' +
    'return null;};' +
    // 轻轻往下滚一屏：单栏布局里评论在图片下面，要滚到才会挂载、才会去请求。
    'var nudgeScroll=function(){var n=0;' +
    'try{window.scrollBy(0,600);n++;}catch(e){}' +
    'try{var all=document.querySelectorAll("div,section,main");' +
    'for(var i=0;i<all.length;i++){var el=all[i];' +
    'try{if(el.scrollHeight>el.clientHeight+80&&el.clientHeight>200){' +
    'el.scrollTop=el.scrollTop+600;n++;}}catch(e){}}}catch(e){}' +
    'return n;};';
/**
 * 生成「在帖子页面上读评论」的脚本（原生侧会先真的导航到该帖页面）。
 *
 * **刻意什么都不点、什么都不滚**（第三代实现）：
 *   上一版靠"点一下页面里那颗评论按钮 + 往下滚一屏"去**逼**页面发评论请求。实测在这台
 *   设备的 IG 版本上，那颗控件点下去会把页面**导航走** —— 脚本的执行上下文连同回调一起
 *   消失，桥只能干等到 20 秒超时，表现就是 `comments payload state=timeout`（反复复现）。
 *   何况这一版 IG 的帖子页首屏**根本不带评论请求**（探针实测：`ul li`=0、内嵌 JSON 里只有
 *   261 字节的 `_sharedData`、`__ogReplay` 里没有 comment 操作名），逼也逼不出来。
 *
 * 所以这里只做三件**只读**的事，按可靠性从高到低：
 *   1) 页面自己已经收到的评论响应（`__ogCommentResps`）；
 *   2) 回放页面发过的那个评论请求（`__ogCommentCfg` / `__ogReplay`，把 first 调大）；
 *   3) 扫描内嵌 JSON（有预算，见 collectEmbedded）。
 * 都没有就快速回报 empty —— 读不到就说读不到，绝不再把桥挂死。
 */
export function commentsOnPostPageScript(): string {
    return '(function(){try{' +
        COMMENTS_JSON_JS +
        // 纯同步：不再 await、不再点、不再滚（理由见上面的说明）。
        // 同一个页面上"同步探针 11ms 就返回、而带 await 的读法 20 秒不返回"是实测事实，
        // 所以这里把异步彻底去掉：能读到就返回，读不到立刻 empty，绝不让桥挂死。
        'var out=[];var seen={};var keys=[];var src="none";' +
        'var resps=window.__ogCommentResps||[];' +
        'for(var r=0;r<resps.length;r++){' +
        'try{var rj=JSON.parse(resps[r]);if(rj)collectInto(rj,out,seen,keys);}catch(e){src="resp-nonjson";}}' +
        'if(out.length>0)src="resp";' +
        'if(out.length===0){' +
        'if(collectEmbedded(out,seen,keys)>0)src=src+"/embedded";else src=src+"/embedded-empty";}' +
        'return JSON.stringify({state:out.length>0?"ok":"empty",items:out,' +
        'diag:"page="+String(location.pathname||"")+" sync src="+src+" resps="+resps.length+' +
        '+" n="+out.length+" keys="+keys.slice(0,4).join("|")});' +
        '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}
/** Reads the current page title and URL for diagnostics and native chrome. */
export const PAGE_STATE_SCRIPT: string = '(function(){return JSON.stringify({title:document.title,url:location.href,ready:document.readyState});})()';

/**
 * 当前页面**记录到的请求名**（`window.__ogReplay` 的键）。
 *
 * 用途：抓模板抓不到东西时，先看"这个页面到底发过哪些请求" —— 比如 IG 的探索页是**服务端直出**
 * （数据内嵌在 HTML 里，一个 XHR 都不发），那就不是抓取姿势的问题，而是这条路根本不存在。
 */
export const REPLAY_NAMES_SCRIPT: string = '(function(){try{' +
  'var rep=window.__ogReplay||{};' +
  'return JSON.stringify({url:location.href,ready:document.readyState,' +
  'watch:!!window.__ogNetWatch,names:Object.keys(rep)});' +
  '}catch(e){return JSON.stringify({error:String(e).slice(0,120)});}})()';

/**
 * 探针用：当前页面里到底有没有**内嵌评论数据**、藏在哪儿（**轻量版**）。
 *
 * 背景：在这台设备的 IG 版本上，"点评论按钮 / 点 reels 的评论图标"都不会发出评论请求，
 * 可网页的评论面板照样能显示 —— 说明评论数据跟着页面内嵌下来了。老读法却一直
 * `state=timeout`，实测**连这个探针脚本都会超时**（12 秒没返回），所以先量清楚：
 *   - 页面里有多少 script、多少个 type=json、多少个含 "comment" 字样；
 *   - 这些脚本各多大（大的就是"解析很贵"的元凶）；
 *   - 只对**体积可控**的脚本试一次 JSON.parse，看能不能解析、键名是什么。
 *
 * 刻意**不**做全量解析（那是老读法慢/超时的原因），只回事实 + 计时，让下一步有据可依。
 */
export const DOM_COMMENTS_PROBE_SCRIPT: string =
  '(function(){try{' +
  'var t0=Date.now();' +
  'var out={path:String(location.pathname).slice(0,40),scripts:0,json:0,withComment:0,' +
  'big:0,parsed:0,items:0,keys:[],sizes:[],samples:[],globals:[],ms:0};' +
  'var all=document.querySelectorAll("script");' +
  'out.scripts=all.length;' +
  'for(var i=0;i<all.length;i++){' +
  'var s=all[i];var ty=String(s.getAttribute("type")||"");' +
  'var t=String(s.textContent||"");var len=t.length;' +
  'if(ty.indexOf("json")>=0)out.json++;' +
  'if(len>500000)out.big++;' +
  'if(len>0&&/comment/i.test(t)){' +
  'out.withComment++;' +
  'if(out.sizes.length<6)out.sizes.push(len);' +
  // 只解析"体积可控"的那些：大脚本一个就能把主线程钉住十几秒（实测整脚本超时）。
  'if(len<=400000){try{var j=JSON.parse(t);if(j){out.parsed++;' +
  'var ks=Object.keys(j);for(var k=0;k<ks.length&&out.keys.length<8;k++)out.keys.push(String(ks[k]));}}catch(e){}}' +
  'else if(out.samples.length<2){out.samples.push("type="+ty+" len="+len+" head="+t.slice(0,70).replace(/\\s+/g," "));}}}' +
  'var gs=["__additionalData","_sharedData","__initialData","__ogCommentResps","__ogCommentCfg"];' +
  'for(var g=0;g<gs.length;g++){try{if(window[gs[g]])out.globals.push(gs[g]);}catch(e){}}' +
  // 评论也可能是**服务端直接渲染进 DOM** 的（那样就永远不会有"评论请求"，也解释得通
  // 为什么 `__ogReplay` 里从来没有 comment 操作名）。这里量一下渲染出来的评论列表：
  // IG 网页的评论是 main 里的 ul > li，每条里通常有个指向作者主页的 a[href="/用户名/"]。
  'var main=document.querySelector("main")||document;' +
  'var lis=main.querySelectorAll("ul li");' +
  'out.lis=lis.length;' +
  'var liSamples=[];' +
  'for(var L=0;L<lis.length&&liSamples.length<3;L++){' +
  'var tx=String(lis[L].textContent||"").replace(/\\s+/g," ").trim();' +
  'if(tx.length>0)liSamples.push(tx.slice(0,90));}' +
  'out.liSamples=liSamples;' +
  'out.articles=document.querySelectorAll("article").length;' +
  'var anchors=main.querySelectorAll("a[href]");var users=0;' +
  'for(var A=0;A<anchors.length;A++){var h=String(anchors[A].getAttribute("href")||"");' +
  'if(/^\\/[A-Za-z0-9._]+\\/$/.test(h))users++;}' +
  'out.userLinks=users;' +
  'try{var sd=window._sharedData;' +
  'if(sd){var s=JSON.stringify(sd);out.sdLen=s.length;out.sdComment=/comment/i.test(s);' +
  'out.sdKeys=Object.keys(sd).slice(0,10);}}catch(e){}' +
  'out.ms=Date.now()-t0;' +
  'return JSON.stringify(out);' +
  '}catch(e){return JSON.stringify({error:String(e).slice(0,120)});}})()';
/**
 * 探针用：把当前页面的 DOM 骨架打出来，用来对着真实结构写选择器。
 * 只输出标签、少量属性、尺寸与命中数量，不带正文内容。
 */
export const DOM_SURVEY_SCRIPT: string = '(function(){try{' +
    'var out=[];' +
    'var sig=function(e){if(!e)return "?";var t=e.tagName?e.tagName.toLowerCase():"?";' +
    'var cls="";try{if(e.className&&typeof e.className==="string"){cls="."+e.className.split(" ").slice(0,2).join(".");}}catch(_){}' +
    'var geo="";try{var r=e.getBoundingClientRect();geo="("+Math.round(r.width)+"x"+Math.round(r.height)+")";}catch(_){}' +
    'return t+cls+geo;};' +
    'var q=function(sel,scope){try{return (scope||document).querySelectorAll(sel);}catch(e){return [];}};' +
    'var cs=[];var probes=["main article","article","[role=article]","main img","main video",' +
    '"a[href*=\\"/p/\\"]","main a[href*=\\"/p/\\"]","main div[style*=transform]"];' +
    'for(var p=0;p<probes.length;p++){cs.push(probes[p]+"="+q(probes[p]).length);}' +
    // 首屏是 SSR：确认页面里是否本来就带着 feed 的 JSON（含 video_versions）。
    'try{var html=document.documentElement.innerHTML;' +
    'cs.push("htmlVideoVersions="+String(html.indexOf("video_versions")>=0));' +
    'cs.push("htmlImageVersions="+String(html.indexOf("image_versions2")>=0));' +
    'cs.push("htmlTimelineConn="+String(html.indexOf("xdt_api__v1__feed__timeline__connection")>=0));' +
    'cs.push("htmlLen="+html.length);}catch(e){}' +
    'out.push("probes:"+cs.join(","));' +
    'var arts=q("article");' +
    'var big=null;var bigImg=null;' +
    'for(var ai=0;ai<arts.length;ai++){' +
    'var imgs=q("img",arts[ai]);' +
    'for(var ii=0;ii<imgs.length;ii++){' +
    'var r=null;try{r=imgs[ii].getBoundingClientRect();}catch(e){}' +
    'if(r&&r.width>=180){big=arts[ai];bigImg=imgs[ii];break;}}' +
    'if(big)break;}' +
    'if(!big){out.push("NO_BIG_POST");var mn=document.querySelector("main");' +
    'out.push("main:"+sig(mn)+" text="+String((mn&&mn.innerText)||"").replace(/\\s+/g," ").slice(0,90));' +
    'return out.join(" || ");}' +
    'out.push("HAS_BIG_POST");' +
    'out.push("art:"+sig(big));' +
    'var up=big.parentElement;var chain=[];var g=0;' +
    'while(up&&g++<5){chain.push(sig(up));up=up.parentElement;}' +
    'out.push("up:"+chain.join(" < "));' +
    'var hd=big.querySelector("header");' +
    'out.push("header:"+sig(hd)+" text="+String((hd&&hd.innerText)||"").replace(/\\s+/g," ").slice(0,60));' +
    'var links=q("a[href]",big);var ls=[];' +
    'for(var l=0;l<links.length&&l<8;l++){' +
    'var h=String(links[l].getAttribute("href")||"");' +
    'if(h.length>0)ls.push(h.slice(0,28)+"~"+String(links[l].textContent||"").replace(/\\s+/g," ").trim().slice(0,14));}' +
    'out.push("links:"+ls.join(" ; "));' +
    'var ims=q("img",big);var il=[];' +
    'for(var m=0;m<ims.length&&m<4;m++){' +
    'var rr=ims[m].getBoundingClientRect();' +
    'il.push(Math.round(rr.width)+"x"+Math.round(rr.height)+"|"+String(ims[m].getAttribute("alt")||"").slice(0,16)+"|"+' +
    'String(ims[m].currentSrc||ims[m].src||"").slice(0,80));}' +
    'out.push("imgs:"+il.join(" ; "));' +
    'var spans=q("span[dir=auto]",big);var sl=[];' +
    'for(var s=0;s<spans.length&&s<6;s++){' +
    'var t=String(spans[s].textContent||"").replace(/\\s+/g," ").trim();' +
    'if(t.length>0)sl.push(t.slice(0,26));}' +
    'out.push("spans:"+sl.join(" / "));' +
    'var bs=q("button",big);var bl=[];' +
    'for(var b=0;b<bs.length&&b<8;b++){' +
    'var al=String(bs[b].getAttribute("aria-label")||"").slice(0,30);' +
    'if(al.length>0)bl.push(al);}' +
    'out.push("buttons:"+bl.join(" / "));' +
    'out.push("text:"+String(big.innerText||"").replace(/\\s+/g," ").slice(0,120));' +
    'return out.join(" || ");' +
    '}catch(e){return "survey-error:"+String(e);}})()';
/**
 * 探针用：把页面自己发出的请求报给原生。
 *
 * 只挂 `fetch` / `XMLHttpRequest`，并额外用 Resource Timing 兜底，
 * 不改请求、不改响应，只上报「方法 + URL + 触发方式」。
 */
export const NETWORK_WATCHER: string = '(function(){try{' +
    'if(window.__ogNetWatch){return;}window.__ogNetWatch=1;' +
    'var tell=function(payload){try{' + PROXY + '.onApiDetail(String(payload));}catch(e){}};' +
    'var pack=function(o){try{return JSON.stringify(o);}catch(e){return "{}";}};' +
    'var mask=function(name,value){var n=String(name||"").toLowerCase();' +
    'if(n.indexOf("csrf")>=0||n.indexOf("cookie")>=0||n.indexOf("authorization")>=0)return n+"=<masked>";' +
    'return n+"="+String(value||"").slice(0,48);};' +
    'var text=function(value,limit){try{return String(value||"").slice(0,limit);}catch(e){return "";}};' +
    // REST 请求的模板名：去掉域名与查询串，只留路径（`/api/v1/discover/ayml/`）。
    // 带 id 的那类（`friendships/create/123/`）也照原样留着：回放时按 id 换路径。
    'var restPath=function(u){try{return String(u||"").split("?")[0].replace(/^https?:\\/\\/[^/]+/,"");}catch(e){return "";}};' +
    'var headersOf=function(init){try{if(!init||!init.headers)return "";var h=init.headers;' +
    'var out=[];if(typeof h.forEach==="function"&&typeof h.get==="function"){h.forEach(function(v,k){out.push(mask(k,v));});}' +
    'else if(Array.isArray(h)){for(var i=0;i<h.length;i++){out.push(mask(h[i][0],h[i][1]));}}' +
    'else{var ks=Object.keys(h);for(var j=0;j<ks.length&&j<12;j++){out.push(mask(ks[j],h[ks[j]]));}}' +
    'return out.join("; ");}catch(e){return "";}};' +
    'var OF_BODY=8000;var OF_RESP=4000;' +
    // ---------------------------------------------------------------------
    // 响应缓存（"探针抓 HTTP 响应"这条快路径的数据源）
    //
    // 页面自己发的请求，响应体已经在页面内存里了。只要把它留一份，原生侧就能**直接解析**
    // 这份响应，而不必再回放一次同样的请求 —— 省掉的是一次完整往返（实测 GraphQL 这一发
    // 首屏 300~900ms）。这就是"抓 HTTP 请求"相对"回放 + DOM 兜底"的全部收益来源。
    //
    // 只留我们在意的两类（信息流 / Clips 即 reels），各留**最新一份**，单份封顶 3MB：
    // 整包响应可能上兆（十几条帖子带全部字段），多留几份等于把 WebView 内存吃掉；
    // 而分页那条（换游标）本来就要发新请求，留着旧页也没用。
    // ---------------------------------------------------------------------
    'var CAP_MAX=3000000;' +
    'var capClass=function(name,url,body){try{' +
    'var n=String(name||"")+" "+String(url||"");' +
    'if(/FeedTimeline|FeedRootPagination/i.test(n))return "feed";' +
    'if(/ClipsTabRoot|ClipsHome|ClipsFeed/i.test(n))return "reels";' +
    // 名字取不到时退回看请求体里的 friendly_name（fetch 那条常常只能从 body 里拿）。
    'var m=String(body||"").match(/fb_api_req_friendly_name=([^&]*)/);' +
    'if(m){var f=decodeURIComponent(m[1]);' +
    'if(/FeedTimeline|FeedRootPagination/i.test(f))return "feed";' +
    'if(/ClipsTabRoot|ClipsHome|ClipsFeed/i.test(f))return "reels";}' +
    '}catch(e){}return "";};' +
    'var capture=function(name,url,body,resp){try{' +
    'var cls=capClass(name,url,body);if(!cls)return;' +
    'var t=String(resp||"");if(t.length===0)return;' +
    'if(!window.__ogCap)window.__ogCap={};' +
    'window.__ogCap[cls]={t:(t.length>CAP_MAX?t.slice(0,CAP_MAX):t),b:String(body||""),' +
    'n:String(name||""),u:String(url||""),at:Date.now(),trunc:t.length>CAP_MAX};' +
    '}catch(e){}};' +
    // 页面内存里留一份「原始」请求配置（含真实 csrftoken），只用于原样回放，
    // 不通过桥传给原生：桥上报的那份把头一律打码了。
    'if(!window.__ogReplay)window.__ogReplay={};' +
    // 按操作名存下可原样回放的请求（探针与兜底查找用）。
    //
    // 这里刻意**不**把它当首页信息流的回放配置，也不在这里通知原生：名字里带
    // FeedTimeline / FeedRootPagination 的请求不止一条（还有缓存 / 订阅之类的变体），
    // 挑错一条就会回放出一个没有 timeline 连接的响应 —— 那正是「只显示两条帖子」。
    // 只有等响应回来、确认里面真的带着首页信息流连接，才在 load 回调里提升为
    // __ogFeedCfg 并通知原生。
    'var remember=function(name,url,method,hs,body){try{if(!name)return;' +
    'window.__ogReplay[name]={u:url,m:method,h:hs,b:body};' +
    '}catch(e){}};' +
    // 评论数据单独留一份「页面刚收到的响应」：读评论时先直接用它 —— 不额外发请求、
    // 不碰 csrf，内容就是页面自己拿到的那份（见 COMMENTS_JSON_JS）。
    //
    // 判据看的是**响应体**而不是请求名：帖子页的评论常常和正文挤在同一个 GraphQL 查询里
    // （名字里根本没有 comment），只看名字会一条都等不到（实测 cfg=-）。
    'var markComment=function(entry,name,resp){try{' +
    'var t=String(resp||"");' +
    'if(!/(comment[^"]{0,40}(connection|edges))|edge_media_to_parent_comment/i.test(t))return;' +
    'if(!window.__ogCommentResps)window.__ogCommentResps=[];' +
    'if(window.__ogCommentResps.length<4)window.__ogCommentResps.push(t.slice(0,4000000));' +
    'if(entry){entry.n=String(name||"");window.__ogCommentCfg=entry;}' +
    'try{' + PROXY + '.onReplayReady("comment");}catch(e){}' +
    '}catch(e){}};' +
    'try{var oo=XMLHttpRequest.prototype.open;' +
    'XMLHttpRequest.prototype.open=function(m,u){try{this.__ogM=m||"GET";this.__ogU=String(u||"");' +
    // REST（`/api/v1/...`）那类请求**没有** x-fb-friendly-name，按老规矩进不了 __ogReplay，
    // 而"为你推荐"（discover/ayml）恰恰是这种：它必须 POST + 带 x-ig-www-claim / fb_dtsg，
    // 那两样只有页面自己发的时候才拿得到。所以这里给它按**路径**起个名（rest_/api/v1/...），
    // 让它也进模板表 —— 原生就能把这条请求原样回放（见 core/NativeNotifications 的 ayml）。
    'if(/\\/api\\/v1\\//.test(this.__ogU))this.__ogName="rest_"+restPath(this.__ogU);' +
    'this.__ogH=[];this.__ogRaw=[];}catch(e){}' +
    'return oo.apply(this,arguments);};}catch(e){}' +
    'try{var sh=XMLHttpRequest.prototype.setRequestHeader;' +
    'XMLHttpRequest.prototype.setRequestHeader=function(n,v){try{' +
    'if(String(n||"").toLowerCase()==="x-fb-friendly-name")this.__ogName=String(v||"");' +
    'if(this.__ogRaw&&this.__ogRaw.length<16)this.__ogRaw.push([String(n||""),String(v||"")]);' +
    'if(this.__ogH&&this.__ogH.length<12)this.__ogH.push(mask(n,v));}catch(e){}return sh.apply(this,arguments);};}catch(e){}' +
    'try{var ss=XMLHttpRequest.prototype.send;' +
    'XMLHttpRequest.prototype.send=function(body){var self=this;try{' +
    'var b=typeof body==="string"?text(body,OF_BODY):(body?"[binary]":"");' +
    // Instagram 的 GraphQL 用 URLSearchParams 提交：它本身就是可以直接回放的表单串，
    // 只有 FormData / Blob 才记不下来。
    'var rb="";try{if(typeof body==="string")rb=body;else if(body){' +
    'var kind=Object.prototype.toString.call(body);' +
    'if(kind!=="[object FormData]"&&kind!=="[object Blob]"&&kind!=="[object ArrayBuffer]")rb=String(body);}}catch(e){}' +
    'if(rb.length>0&&rb.indexOf("[object")!==0){' +
    'if(typeof body!=="string")b=text(rb,OF_BODY);' +
    // 给这条请求本身留一份配置（而不是按操作名共享一份）：响应确认后据此提升，
    // 避免同名请求互相覆盖导致提升到别的请求的配置。
    'self.__ogEntry={u:self.__ogU,m:self.__ogM,h:self.__ogRaw,b:rb};' +
    'remember(self.__ogName,self.__ogU,self.__ogM,self.__ogRaw,rb);' +
    // 点赞 / 转发的变更也第一时间通知原生去存模板：它们只在该文档里存在，
    // 而这两条路（尤其"导航到帖子页再点"那条）随时可能整页重载，晚一步就没了。
    'if(self.__ogName&&/LikeMediaXIG|MediaRepost|SaveMedia|UnsaveMedia|MediaSave/i.test(String(self.__ogName))){' +
    'try{' + PROXY + '.onEngageTemplate(String(self.__ogName));}catch(e){}}' +
    // 和 fetch 那条一样：XHR 上的评论请求也要第一时间通知原生去存模板。
    'if(!window.__ogCommentCfg&&self.__ogName&&/comment/i.test(String(self.__ogName))){' +
    'window.__ogCommentCfg=self.__ogEntry;try{' + PROXY + '.onCommentTemplate(String(self.__ogName));}catch(e){}}}' +
    'tell(pack({m:self.__ogM||"GET",u:self.__ogU||"",k:"xhr",b:b,h:(self.__ogH||[]).join("; "),' +
    'f:self.__ogName||""}));' +
    'if(!self.__ogResp){self.__ogResp=1;' +
    'self.addEventListener("load",function(){try{' +
    'var full=String(self.responseText||"");' +
    // 响应里真的带着首页信息流连接，这条配置才配当回放目标；同时这才是
    // 「页面已经发过一次 feed 请求」的可靠信号，原生据此结束等待。
    'if(self.__ogEntry&&full.indexOf("xdt_api__v1__feed__timeline__connection")>=0){' +
    'window.__ogFeedCfg=self.__ogEntry;' +
    'try{' + PROXY + '.onReplayReady(String(self.__ogName||"feed"));}catch(e){}}' +
    // 留一份响应给原生直接解析（见 capture 的说明）。放在这里而不是探针里：
    // 这是快路径的数据源，和"要不要看探针报告"无关。
    'capture(self.__ogName,self.__ogU,(self.__ogEntry?self.__ogEntry.b:""),full);' +
    'markComment(self.__ogEntry,self.__ogName,full);' +
    // 响应体只有**开着探针**时才回传：一轮 SPA 会发几十个请求，每个都把最多 4000 字符
    // 序列化过桥一次，是纯开销（取数速度优化时实测过这笔账）。要采样时由探针面板
    // 注入 PROBE_WATCH_ON_SCRIPT 打开。
    'var t=full.slice(0,OF_RESP);' +
    'if(t.length>0&&window.__ogProbeOn)tell(pack({m:"RESP",u:self.__ogU||"",k:self.__ogName||"xhr",b:t}));}catch(e){}});}}catch(e){}' +
    'return ss.apply(this,arguments);};}catch(e){}' +
    // 信息流的 GraphQL 实际走的是 fetch（探针报告里是 [fetch] POST /graphql/query），
    // 所以 fetch 这条也必须和 XHR 那条一样存一份可原样回放的配置 —— 否则原生侧
    // 永远拿不到回放目标，只能退回 SSR 里内嵌的那两三条，翻页也无从下手。
    'var rawHeaders=function(init){try{if(!init||!init.headers)return [];var h=init.headers;var out=[];' +
    'if(typeof h.forEach==="function"&&typeof h.get==="function"){h.forEach(function(v,k){out.push([String(k),String(v)]);});}' +
    'else if(Array.isArray(h)){for(var i=0;i<h.length;i++){out.push([String(h[i][0]),String(h[i][1])]);}}' +
    'else{var ks=Object.keys(h);for(var j=0;j<ks.length;j++){out.push([String(ks[j]),String(h[ks[j]])]);}}' +
    'return out;}catch(e){return [];}};' +
    'var rawHeader=function(list,nm){try{for(var i=0;i<list.length;i++){' +
    'if(String(list[i][0]).toLowerCase()===nm)return String(list[i][1]);}}catch(e){}return "";};' +
    // 回放要用完整请求体（不能截断），URLSearchParams 也一并转成表单串。
    'var fullBody=function(init){try{if(!init||init.body===undefined||init.body===null)return "";' +
    'if(typeof init.body==="string")return String(init.body);' +
    'var kd=Object.prototype.toString.call(init.body);' +
    'if(kd==="[object URLSearchParams]"||kd==="[object String]")return String(init.body);' +
    '}catch(e){}return "";};' +
    'var bodyName=function(body){try{var m=String(body||"").match(/fb_api_req_friendly_name=([^&]*)/);' +
    'return m?decodeURIComponent(m[1]):"";}catch(e){return "";}};' +
    'var of=window.fetch;' +
    'if(typeof of==="function"){window.fetch=function(input,init){try{' +
    'var url=(typeof input==="string")?input:((input&&input.url)||"");' +
    'var method=(init&&init.method)||((input&&input.method)||"GET");' +
    'var braw=fullBody(init);var rh=rawHeaders(init);' +
    'var fname=rawHeader(rh,"x-fb-friendly-name")||bodyName(braw);' +
    // REST（/api/v1/...）也按路径起名，理由同 XHR 那条（见 open 钩子）。
    'if(!fname&&/\\/api\\/v1\\//.test(String(url)))fname="rest_"+restPath(url);' +
    'var entry=null;' +
    // `init.__ogQuiet` = 「这一发是原生侧的回放，不是页面自己发的」（见 timelineScript）。
    // 回放出来的请求**不能**写进 __ogReplay / __ogFeedCfg —— 那两个槽位的含义是
    // 「页面自己最近发过哪条请求」，翻页兜底（滚页面 → 等页面自己发下一页 → 回放它刚发的
    // 那一条）全靠它。被我们自己的旧游标请求覆盖之后，兜底回放到的永远是我们自己那一页，
    // 翻页会**静默停死**：表现就是上滑很多轮之后再也要不出新帖子（游标这条路一旦失效，
    // 兜底这条路也已经被自己污染了）。
    // 标记直接挂在 fetch 的 init 上而不是用全局开关：全局开关会被页面自己的请求误伤
    // （触发点击后页面紧接着发的那条 feed 请求正好落在窗口里），而且脚本被导航打断时
    // 还会永久残留。init 里的多出来的键 fetch 会忽略，只给我们自己看。
    'var quiet=!!(init&&init.__ogQuiet);' +
    'if(fname&&braw.length>0&&!quiet){entry={u:String(url),m:String(method||"POST"),h:rh,b:braw,n:String(fname)};' +
    'if(!window.__ogReplay)window.__ogReplay={};window.__ogReplay[fname]=entry;' +
    // 点赞 / 转发 / **收藏**的变更（同为可回放的写请求）也立刻通知原生去存模板，
    // 理由见 XHR 那条：收藏这条原生 route 要 App 身份的会话，我们手上只有网页会话，
    // 所以只能靠"页面自己发过一次"抓下模板再原样回放（见 core/NativeSave）。
    'if(/LikeMediaXIG|MediaRepost|SaveMedia|UnsaveMedia|MediaSave/i.test(String(fname))){' +
    'try{' + PROXY + '.onEngageTemplate(String(fname));}catch(e){}}' +
    // 评论请求一发出来就告诉原生：那次请求的配置只在**当前文档**里有效，回首页整页重载就没了。
    // 网页里"点开一条帖子"是 SPA 换路由（不触发 pageReady），原生自己猜时机猜不准，所以由
    // 页面在最准确的这一刻通知它去存模板。只报一次，避免刷桥。
    'if(entry&&!window.__ogCommentCfg&&/comment/i.test(String(fname))){' +
    'window.__ogCommentCfg=entry;try{' + PROXY + '.onCommentTemplate(String(fname));}catch(e){}}}' +
    'if(window.__ogProbeOn)tell(pack({m:method,u:String(url),k:"fetch",b:text(braw,OF_BODY),h:headersOf(init),f:fname}));' +
    'var p=of.apply(this,arguments);' +
    'try{p.then(function(res){try{if(res&&res.clone){' +
    'res.clone().text().then(function(t){var full=String(t||"");' +
    // 与 XHR 同一条规矩：只有响应真的带着首页信息流连接，才提升 / 通知原生。
    'if(entry&&full.indexOf("xdt_api__v1__feed__timeline__connection")>=0){' +
    'window.__ogFeedCfg=entry;' +
    'try{' + PROXY + '.onReplayReady(String(fname||"feed"));}catch(e){}}' +
    'capture(fname,String(url),braw,full);' +
    'markComment(entry,fname,full);' +
    'if(full.length>0&&window.__ogProbeOn)tell(pack({m:"RESP",u:String(url),k:"fetch",b:full.slice(0,OF_RESP)}));});}}catch(e){}});}catch(e){}' +
    'return p;}catch(e){return of.apply(this,arguments);}};}' +
    // 资源时间线也只采样请求名（本来就是短串）。它跟"探针开没开"无关地一直跑，
    // 但每条都是一次过桥调用，所以同样只在探针打开时上报。
    'try{if(window.PerformanceObserver){var seen={};' +
    'var po=new PerformanceObserver(function(list){try{var es=list.getEntries();' +
    'for(var i=0;i<es.length;i++){var e=es[i];var it=String(e.initiatorType||"");' +
    'if(it!=="fetch"&&it!=="xmlhttprequest")continue;' +
    'var n=String(e.name||"");if(!n||seen[n])continue;seen[n]=1;' +
    'if(window.__ogProbeOn)tell(pack({m:"GET",u:n,k:it,b:"",h:""}));}' +
    '}catch(e){}});po.observe({type:"resource",buffered:true});}}catch(e){}' +
    '}catch(e){}})();';
/**
 * 打开"请求/响应回传"开关（探针面板用）。
 *
 * `NETWORK_WATCHER` 里每条请求/响应的上报都是**过桥**调用，一轮页面加载几十条，
 * 是纯粹的常驻开销 —— 所以默认关掉，只有真要看探针报告时才打开。
 * 注意它挂在当前文档上，页面重载后要重新注入（探针面板每次打开都会注入）。
 */
export const PROBE_WATCH_ON_SCRIPT: string = '(function(){try{window.__ogProbeOn=true;return "probe-on";}catch(e){return "probe-error";}})()';
/* ==========================================================================
 * 页面会话令牌（按需读取，不再"等用户先点一次"去抓模板）
 *
 * 背景：IG 的写类接口（点赞 / 转发 / ayml）除了 Cookie + csrftoken，还要一串
 * **每次页面加载都会变**的令牌与指纹。以前我们只能靠"页面自己发过一次，把那条请求
 * 原样存成模板"来拿到它们 —— 代价是新装/换会话后必须先手动做一次同类动作。
 *
 * 真机探针确认这些值都能**只读地**从当前页面拿到（不需要发任何写请求）：
 *   lsd / fb_dtsg   → `require("LSD").token` / `require("DTSGInitialData").token`
 *   jazoest         → 客户端算出来的（= "2" + fb_dtsg 各字符码之和，见 core/WebTokens）
 *   __rev           → `require("SiteData").server_revision`（同一个值也是 x-instagram-ajax）
 *   __hsi           → `require("SiteData").hsi`
 *   __hs/__dyn/__csr/__s → 页面自己刚发过的请求 URL 里带着（performance 资源表里取一条）
 *   av/账号 id      → Cookie 罐里的 ds_user_id（原生侧直接读，不经页面）
 *
 * 返回 JSON；取不到的字段留空，调用方按"缺了就回退抓模板"处理。
 * ========================================================================== */
export const PAGE_TOKENS_SCRIPT: string = '(function(){try{var out={ok:1};' +
  'var R=function(n){try{return window.require?window.require(n):null;}catch(e){return null;}};' +
  'try{out.lsd=String((R("LSD")||{}).token||window.lsd||"");}catch(e){}' +
  'try{out.dtsg=String((R("DTSGInitialData")||{}).token||"");}catch(e){}' +
  'try{var s=R("SiteData")||{};out.rev=String(s.server_revision||"");' +
  'out.hsi=String(s.hsi||"");out.spin=String(s.__spin_r||s.server_revision||"");' +
  'out.spinb=String(s.__spin_b||"trunk");}catch(e){}' +
  // 页面自己发过的请求 URL：__hs / __dyn / __csr / __s / __rev / __hsi 都在查询串里。
  'try{var es=(typeof performance!=="undefined"&&performance.getEntriesByType)?' +
  'performance.getEntriesByType("resource"):[];' +
  'for(var i=0;i<es.length;i++){var u=String(es[i].name||"");' +
  'if(u.indexOf("__dyn=")>=0){out.url=u.slice(0,2000);break;}}}catch(e){}' +
  'return JSON.stringify(out);}catch(e){return JSON.stringify({ok:0,error:String(e)});}})()';

/* ==========================================================================
 * 回放 API（探针抓到的请求模板）
 *
 * 背景：NETWORK_WATCHER 会给每一条带 x-fb-friendly-name（或 body 里带
 * fb_api_req_friendly_name）的请求存一份**可原样回放**的配置到 `window.__ogReplay[操作名]`。
 * 信息流快路径只用了其中 timeline 那一条（见 timelineScript / __ogFeedCfg）；这一节把
 * 「网页里到底有哪些模板、每个有哪些旋钮」也交给原生 —— reels / 私信 / 搜索 / 个人页
 * 以后照同一套接就行，不用每次重新靠滚动逼网页发请求。
 *
 * 为什么模板只能现抓现用、不能写死：IG 会改操作名、doc_id 和变量结构，请求里还带着
 * lsd / fb_dtsg 这类令牌 —— 只有「让页面用它自己刚发过的那个请求」才长期有效。
 * ========================================================================== */
/**
 * GraphQL 表单体的变量合并（下面两个回放脚本共用）。
 *
 * 请求体就是 `variables=<urlencoded json>`，把原生给的旋钮（游标、first、media_id /
 * shortcode 之类）合进那个对象即可。模板里没有的键也照样写进去 —— GraphQL 会忽略不认识的
 * 变量，写进去比少写更好排查。
 *
 * 取值语义：**null = 把这个键删掉**（用来清掉模板里带的分页游标，回到第一页）；
 * undefined / 不传 = 保持模板原值。
 */
/**
 * 展示用的目标宽度（像素）：媒体降级到这一档，下载仍然给原图。
 *
 * 1080 在本机（1280px 宽屏）全宽显示看不出差别，而 IG 的 1080 档通常只有 1440/2160 档的
 * 一半到三分之一大小 —— 这是 feeds/reels 流量的大头之一（见 core/MediaQuality）。
 */
const TARGET_MEDIA_WIDTH: number = 1080;

/**
 * 媒体挑选（展示降级 + 原图下载），信息流与 reels 的脚本共用。
 *
 * 和原生侧 core/MediaQuality 是**同一套判据**（原生解析、页面脚本解析两条路必须一致，
 * 否则会出现"走网页时清晰度对、走原生时不对"这种最难查的问题）：
 *   - 展示用：宽度 ≥ TARGET_W 里**最小的那一档**（够清晰又最省流量）；
 *   - 下载用：最大的一档（original=true）。
 */
const MEDIA_PICK_JS: string =
  'var TARGET_W=' + String(TARGET_MEDIA_WIDTH) + ';' +
  'var pickBest=function(urls,ws,hs,target){var best=null;var fb=null;var unk=null;' +
  'for(var i=0;i<urls.length;i++){var url=urls[i];if(!url)continue;' +
  'var w=Number(ws[i])||0;var h=Number(hs[i])||0;' +
  'if(w<=0){if(!unk)unk={url:String(url),w:0,h:h};continue;}' +
  'if(target<0){if(!best||w>best.w)best={url:String(url),w:w,h:h};continue;}' +
  'if(w>=target){if(!best||w<best.w)best={url:String(url),w:w,h:h};}' +
  'else if(!fb||w>fb.w){fb={url:String(url),w:w,h:h};}}' +
  'return best||fb||unk||{url:"",w:0,h:0};};' +
  'var pickImage=function(iv,original){var urls=[];var ws=[];var hs=[];try{' +
  'var cs=(iv&&iv.candidates)||[];' +
  'for(var i=0;i<cs.length;i++){var c=cs[i];if(!c||!c.url)continue;' +
  'urls.push(String(c.url));ws.push(Number(c.width)||0);hs.push(Number(c.height)||0);}' +
  '}catch(e){}return pickBest(urls,ws,hs,original?-1:TARGET_W);};' +
  'var pickVideo=function(m,original){var urls=[];var ws=[];var hs=[];try{' +
  'var vs=m.video_versions||[];' +
  'for(var i=0;i<vs.length;i++){var v=vs[i];if(!v||!v.url)continue;' +
  'urls.push(String(v.url));ws.push(Number(v.width)||0);hs.push(Number(v.height)||0);}' +
  '}catch(e){}return pickBest(urls,ws,hs,original?-1:TARGET_W);};';

const GRAPHQL_VARS_JS: string = 'var mergeVars=function(body,patch){try{' +    'var parts=String(body||"").split("&");' +
    'for(var i=0;i<parts.length;i++){' +
    'if(parts[i].indexOf("variables=")!==0)continue;' +
    'var obj=JSON.parse(decodeURIComponent(parts[i].substring(10)));' +
    'if(!obj||typeof obj!=="object")return body;' +
    'var ks=Object.keys(patch);' +
    'for(var k=0;k<ks.length;k++){' +
    'var key=ks[k];var v=patch[key];' +
    'if(v===undefined)continue;' +
    'if(v===null){delete obj[key];if(obj.data&&typeof obj.data==="object")delete obj.data[key];continue;}' +
    'if(obj[key]===undefined&&obj.data&&typeof obj.data==="object"&&obj.data[key]!==undefined)obj[key]=v;' +
    'else obj[key]=v;}' +
    'parts[i]="variables="+encodeURIComponent(JSON.stringify(obj));' +
    'return parts.join("&");}' +
    // 少数接口整串就是 JSON。
    'if(String(body).charAt(0)==="{"){var j=JSON.parse(body);' +
    'if(j&&j.variables&&typeof j.variables==="object"){' +
    'var k2=Object.keys(patch);' +
    'for(var i2=0;i2<k2.length;i2++){' +
    'if(patch[k2[i2]]===undefined)continue;' +
    'if(patch[k2[i2]]===null){delete j.variables[k2[i2]];continue;}' +
    'j.variables[k2[i2]]=patch[k2[i2]];}return JSON.stringify(j);}}' +
    '}catch(e){}return body;};';
/**
 * 接口索引：把网页里缓存的**全部**可回放模板列给原生。
 *
 * 只回元信息（操作名 / 方法 / URL / 请求体长度 / 变量名），**不带请求体与响应体**：
 * 一轮页面几十条请求，带体过桥是纯开销（探针的响应上报默认关掉就是这个原因）。
 * 变量名是关键 —— 它告诉原生「这条接口有哪些旋钮可调」（游标、first、media_id…）。
 */
export const REPLAY_INDEX_SCRIPT: string = '(function(){try{' +
    'var rep=window.__ogReplay||{};var ks=Object.keys(rep);' +
    'var items=[];' +
    'for(var i=0;i<ks.length&&items.length<40;i++){' +
    'var n=String(ks[i]);var c=rep[n]||{};var body=String(c.b||"");' +
    'var vars=[];' +
    'try{' +
    'var m=body.match(/(?:^|&)variables=([^&]*)/);' +
    'var raw=m?decodeURIComponent(m[1]):(body.charAt(0)==="{"?body:"");' +
    'if(raw){var o=JSON.parse(raw);' +
    'if(o&&typeof o==="object"){' +
    'var ok=Object.keys(o);' +
    'for(var v=0;v<ok.length&&v<14;v++)vars.push(String(ok[v]));' +
    'if(o.data&&typeof o.data==="object"){' +
    'var dk=Object.keys(o.data);' +
    'for(var d=0;d<dk.length&&vars.length<18;d++)vars.push("data."+String(dk[d]));}}}}catch(e){}' +
    'items.push({n:n.slice(0,90),m:String(c.m||""),u:String(c.u||"").slice(0,150),' +
    'b:body.length,v:vars});}' +
    'return JSON.stringify({state:"ok",n:items.length,watch:!!window.__ogProbeOn,' +
    'feed:!!window.__ogFeedCfg,comment:!!window.__ogCommentCfg,items:items});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
/**
 * 通用回放：按**操作名（或名字片段）**重放页面自己发过的那个请求。
 *
 * 典型的接口是 GraphQL 的 POST /graphql/query：`variables=` 里带着分页游标与目标对象，
 * 所以调用方只要给 `vars` 就能换一条帖子/下一页。返回原始响应文本（可截断），
 * 解析交给原生 —— 这样这条通道对所有接口都是同一套，不用为每个接口写一个脚本。
 *
 * @param op 操作名（精确，如 PolarisFeedTimelineRootV2Query）或片段（如 comment）。
 * @param varsJson JSON 对象字符串：要覆盖/补进 variables 的键值。
 * @param maxBytes 响应体回传上限（0 用默认 200000）。
 */
export function replayApiScript(op: string, varsJson: string, maxBytes: number): string {
    const opLiteral: string = JSON.stringify(op);
    const varsLiteral: string = JSON.stringify(varsJson);
    const cap: number = maxBytes > 0 ? maxBytes : 200000;
    return '(async function(){try{' +
        'var OP=' + opLiteral + ';var VARS=JSON.parse(' + varsLiteral + ');var CAP=' + cap + ';' +
        SLEEP_JS +
        GRAPHQL_VARS_JS +
        'var rep=window.__ogReplay||{};var name="";var cfg=rep[OP]||null;' +
        'if(!cfg){var re=null;try{re=new RegExp(OP,"i");}catch(e){}' +
        'var ks=Object.keys(rep);' +
        'for(var i=0;i<ks.length;i++){if(re&&re.test(ks[i])){name=ks[i];cfg=rep[ks[i]];break;}}}' +
        'if(!cfg)return JSON.stringify({state:"no-config",op:OP,' +
        'have:Object.keys(rep).slice(0,20).join(",")});' +
        'if(!name)name=OP;' +
        'var headers={};var hs=cfg.h||[];' +
        'for(var h=0;h<hs.length;h++){headers[hs[h][0]]=hs[h][1];}' +
        'var body=String(cfg.b||"");' +
        'if(body.length>0&&VARS&&typeof VARS==="object")body=mergeVars(body,VARS);' +
        'body=body.replace(/__req=[^&]*/,"__req="+Math.random().toString(36).slice(2,4));' +
        'var t0=Date.now();var http=0;var txt="";' +
        'try{' +
        'var ac=new AbortController();var tm=setTimeout(function(){ac.abort();},9000);' +
        'var res=await fetch(String(cfg.u||""),{method:String(cfg.m||"POST"),credentials:"include",' +
        'headers:headers,body:(body.length>0?body:undefined),signal:ac.signal});' +
        'clearTimeout(tm);if(res){http=res.status;txt=await res.text();}' +
        '}catch(e){return JSON.stringify({state:"fetch-error",op:name,ms:Date.now()-t0,' +
        'message:String(e).slice(0,120)});}' +
        'var trunc=txt.length>CAP;' +
        'return JSON.stringify({state:"ok",op:name,http:http,ms:Date.now()-t0,bytes:txt.length,' +
        'trunc:trunc,body:trunc?txt.slice(0,CAP):txt});' +
        '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}
/**
 * 评论回放（不导航）：页面里已经缓存了评论接口模板时，直接重放它拿评论。
 *
 * ⚠️ 目前**没有调用方**（暂时保留，不是遗漏）：评论现在走 commentsByStoredCfgScript ——
 * 模板存在原生侧，跨页面（读完评论会 `loadUrl` 回首页）也还在。这一条只认"当前这一份
 * 文档里恰好有评论模板"的情况，留着是为了将来先在页面上确认模板、再决定要不要存。
 *
 * 模板不存在（例如刚启动、还没打开过任何帖子页）时回 no-cfg。
 * 返回 {state, items, diag}，字段与 commentsOnPostPageScript 一致，原生那边共用一套解析。
 */
export function commentsByReplayScript(shortcode: string, mediaId: string, first: number): string {
    const codeLiteral: string = JSON.stringify(shortcode);
    const mediaLiteral: string = JSON.stringify(mediaId);
    const count: number = first > 0 ? first : 50;
    return '(async function(){try{' +
        'var CODE=' + codeLiteral + ';var MEDIA=' + mediaLiteral + ';var FIRST=' + count + ';' +
        SLEEP_JS +
        COMMENTS_JSON_JS +
        GRAPHQL_VARS_JS +
        'var cfg=findCommentCfg();' +
        'if(!cfg)return JSON.stringify({state:"no-cfg"});' +
        // media_id 用帖子 id 里 `_` 前面那段；模板里是别的帖子的值也不怕，下面会覆盖。
        'var target={first:FIRST,after:null,last:null};' +
        'if(MEDIA.length>0)target.media_id=MEDIA;' +
        'if(CODE.length>0)target.shortcode=CODE;' +
        'var headers={};var hs=cfg.h||[];' +
        'for(var h=0;h<hs.length;h++){headers[hs[h][0]]=hs[h][1];}' +
        'var body=mergeVars(String(cfg.b||""),target);' +
        'body=body.replace(/__req=[^&]*/,"__req="+Math.random().toString(36).slice(2,4));' +
        'var t0=Date.now();var http=0;var out=[];var seen={};var keys=[];var src="replay";' +
        'try{' +
        'var ac=new AbortController();var tm=setTimeout(function(){ac.abort();},9000);' +
        'var res=await fetch(String(cfg.u||""),{method:String(cfg.m||"POST"),credentials:"include",' +
        'headers:headers,body:(body.length>0?body:undefined),signal:ac.signal});' +
        'clearTimeout(tm);if(res){http=res.status;var txt=await res.text();var json=null;' +
        'try{json=JSON.parse(txt);}catch(e){}' +
        'if(json)collectInto(json,out,seen,keys);else src="replay-nonjson";}' +
        '}catch(e){src="replay-error";}' +
        'var name=String(cfg.n||cfg.u||"").slice(0,48);' +
        'return JSON.stringify({state:out.length>0?"ok":"empty",items:out,' +
        'diag:"src="+src+" http="+http+" ms="+(Date.now()-t0)+" cfg="+name+' +
        '+" n="+out.length+" keys="+keys.slice(0,4).join("|")});' +
        '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}

// ==========================================================================
// 跨页面回放：把模板存到原生侧
//
// 上面那套（REPLAY_INDEX_SCRIPT / replayApiScript / commentsByReplayScript）依赖
// `window.__ogReplay`，而它**只活在当前这一份文档里**。实测：本项目所有"打开网页"都是整页
// `loadUrl`，页面一重载模板就重建了（日志里清单从 7 条掉回 3 条）。
//
// 于是评论那条快路径实际是空转的：评论模板是在帖子页抓到的，而读完评论会 `loadUrl` 回首页，
// 模板当场被冲掉。要让"回放"真正跨页生效，模板必须落到原生侧 —— 也就是下面这一组：
//   1) replayTemplatesScript：把匹配的完整模板（方法/URL/头/体）倒给原生；
//   2) replayStoredApiScript / commentsByStoredCfgScript：用原生存下来的模板发同一个请求。
// 会话与凭据仍然是页面自己的（credentials:"include"），原生不自己构造请求。
// ==========================================================================

/**
 * 把匹配的**完整请求模板**倒出来（方法 / URL / 请求头 / 请求体）。
 *
 * 只回匹配的少数几条、请求体按 maxBody 截断：这是少数几次"带体过桥"，别把整页几十条都
 * 拖过去。返回每条 {n,u,m,h,b,trunc} + have（当前页认得的所有操作名，便于排查）。
 */
export function replayTemplatesScript(filter: string, maxItems: number, maxBody: number): string {
  const filterLiteral: string = JSON.stringify(filter);
  const items: number = maxItems > 0 ? maxItems : 4;
  const cap: number = maxBody > 0 ? maxBody : 6000;
  return '(function(){try{' +
    'var F=' + filterLiteral + ';var N=' + items + ';var CAP=' + cap + ';' +
    'var rep=window.__ogReplay||{};var ks=Object.keys(rep);' +
    'var re=null;try{re=new RegExp(F,"i");}catch(e){}' +
    'var out=[];' +
    'for(var i=0;i<ks.length&&out.length<N;i++){' +
    'if(re&&!re.test(ks[i]))continue;' +
    'var c=rep[ks[i]]||{};var b=String(c.b||"");var h=[];var hs=c.h||[];' +
    'for(var j=0;j<hs.length&&j<20;j++){h.push([String(hs[j][0]),String(hs[j][1])]);}' +
    'out.push({n:String(ks[i]),u:String(c.u||""),m:String(c.m||"POST"),h:h,' +
    'b:(b.length>CAP?b.slice(0,CAP):b),trunc:b.length>CAP});}' +
    // 兜底：信息流那条请求**未必有 friendly name**（探测报告里就出现过这种情况：请求发出去了、
    // 响应也确认带 timeline 连接，但名字是空的，进不了 __ogReplay）。这种时候它只存在于
    // __ogFeedCfg（NETWORK_WATCHER 为它单独留的槽位），按名字扫是扫不到的 ——
    // 于是"存信息流模板"永远 nothing，落盘的模板只能靠上一次会话的旧货。
    // 判据：过滤器提到 feed、按名字又一条没扫到，就把这条 cfg 当成信息流模板倒出来
    // （给个固定名 PolarisFeedTimeline，原生侧就是按这个名字片段找它的）。
    'if(out.length===0&&window.__ogFeedCfg&&/feed/i.test(F)){' +
    'var fc=window.__ogFeedCfg;var fb=String(fc.b||"");var fh=[];var fhs=fc.h||[];' +
    'for(var q=0;q<fhs.length&&q<20;q++){fh.push([String(fhs[q][0]),String(fhs[q][1])]);}' +
    'if(String(fc.u||"").length>0&&fb.length>0){' +
    'out.push({n:"PolarisFeedTimeline",u:String(fc.u||""),m:String(fc.m||"POST"),h:fh,' +
    'b:(fb.length>CAP?fb.slice(0,CAP):fb),trunc:fb.length>CAP,fromCfg:true});}}' +
    'return JSON.stringify({state:"ok",n:out.length,items:out,have:ks.slice(0,20).join(",")});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}

/**
 * 用**原生存下来的模板**回放（不问当前页面有没有这个操作）。
 *
 * @param cfgJson 模板 JSON：`{u,m,h:[[name,value],...],b}`（原生侧已去掉 cookie 一类禁改头）。
 * @param varsJson JSON 对象字符串：要覆盖/补进 variables 的键值（null = 删掉该键）。
 */
export function replayStoredApiScript(cfgJson: string, varsJson: string, maxBytes: number): string {
  const cfgLiteral: string = JSON.stringify(cfgJson);
  const varsLiteral: string = JSON.stringify(varsJson);
  const cap: number = maxBytes > 0 ? maxBytes : 200000;
  return '(async function(){try{' +
    'var CFG=JSON.parse(' + cfgLiteral + ');var VARS=JSON.parse(' + varsLiteral + ');var CAP=' + cap + ';' +
    GRAPHQL_VARS_JS +
    'var headers={};var hs=CFG.h||[];' +
    'for(var h=0;h<hs.length;h++){headers[hs[h][0]]=hs[h][1];}' +
    'var body=String(CFG.b||"");' +
    'if(body.length>0&&VARS&&typeof VARS==="object")body=mergeVars(body,VARS);' +
    'body=body.replace(/__req=[^&]*/,"__req="+Math.random().toString(36).slice(2,4));' +
    'var t0=Date.now();var http=0;var txt="";' +
    'try{' +
    'var ac=new AbortController();var tm=setTimeout(function(){ac.abort();},9000);' +
    'var res=await fetch(String(CFG.u||""),{method:String(CFG.m||"POST"),credentials:"include",' +
    'headers:headers,body:(body.length>0?body:undefined),signal:ac.signal});' +
    'clearTimeout(tm);if(res){http=res.status;txt=await res.text();}' +
    '}catch(e){return JSON.stringify({state:"fetch-error",ms:Date.now()-t0,' +
    'message:String(e).slice(0,120)});}' +
    'var trunc=txt.length>CAP;' +
    'return JSON.stringify({state:"ok",http:http,ms:Date.now()-t0,bytes:txt.length,trunc:trunc,' +
    'body:trunc?txt.slice(0,CAP):txt});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}

/**
 * 用**原生存下来的模板**回放一次，并回一份**结构摘要**（键路径 + 值预览）。
 *
 * 为什么要有它：要照 IG 真实结构写原生页面（我的 / 搜索 / Reels），得先看清接口返回长什么样。
 * 直接把几百 KB 的响应过桥回原生太重，也不好在 ArkTS 里动态摸结构；这里在页面侧走一遍，
 * 只回"路径 = 类型/值预览"的短清单（有键数上限），一次就能照着写解析。
 *
 * 刻意写小（脚本体积本身在实机上是个坑，见 README 里的说明）：不引任何大助手包。
 */
export function replayDigestScript(cfgJson: string, varsJson: string,
                                   maxDepth: number, maxKeys: number): string {
  const cfgLiteral: string = JSON.stringify(cfgJson);
  const varsLiteral: string = JSON.stringify(varsJson);
  const depth: number = maxDepth > 0 ? maxDepth : 5;
  const keys: number = maxKeys > 0 ? maxKeys : 120;
  return '(async function(){try{' +
    'var CFG=JSON.parse(' + cfgLiteral + ');var VARS=JSON.parse(' + varsLiteral + ');' +
    'var MAXD=' + depth + ';var MAXK=' + keys + ';' +
    GRAPHQL_VARS_JS +
    'var headers={};var hs=CFG.h||[];' +
    'for(var h=0;h<hs.length;h++){headers[hs[h][0]]=hs[h][1];}' +
    'var body=String(CFG.b||"");' +
    'if(body.length>0&&VARS&&typeof VARS==="object")body=mergeVars(body,VARS);' +
    'body=body.replace(/__req=[^&]*/,"__req="+Math.random().toString(36).slice(2,4));' +
    'var t0=Date.now();var http=0;var txt="";' +
    'try{var ac=new AbortController();var tm=setTimeout(function(){ac.abort();},9000);' +
    'var res=await fetch(String(CFG.u||""),{method:String(CFG.m||"POST"),credentials:"include",' +
    'headers:headers,body:(body.length>0?body:undefined),signal:ac.signal});' +
    'clearTimeout(tm);if(res){http=res.status;txt=await res.text();}' +
    '}catch(e){return JSON.stringify({state:"fetch-error",ms:Date.now()-t0,message:String(e).slice(0,120)});}' +
    'var json=null;try{json=JSON.parse(txt);}catch(e){}' +
    'if(!json)return JSON.stringify({state:"non-json",http:http,len:txt.length});' +
    'var out=[];' +
    'var prev=function(v){var s=String(v==null?"":v);return s.length>38?s.slice(0,38):s;};' +
    'var walk=function(node,path,d){' +
    'if(out.length>=MAXK)return;' +
    'if(node===null){out.push(path+"=null");return;}' +
    'var t=Object.prototype.toString.call(node);' +
    'if(t==="[object Array]"){out.push(path+"[] n="+node.length);' +
    'if(node.length>0&&d<MAXD)walk(node[0],path+"[0]",d+1);return;}' +
    'if(typeof node!=="object"){out.push(path+"="+prev(node));return;}' +
    'var ks=Object.keys(node);' +
    'for(var i=0;i<ks.length;i++){if(out.length>=MAXK)return;' +
    'walk(node[ks[i]],path+"."+ks[i],d+1);}};' +
    'walk(json,"",0);' +
    'return JSON.stringify({state:"ok",http:http,ms:Date.now()-t0,n:out.length,keys:out});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}

/**
 * 「我的」头部：用存下来的模板回放一次，只回**要用的字段**。
 *
 * 为什么不让原生读整包 JSON：那条查询响应 3~5KB 还好，但帖子列表那条一条就 70KB+
 * （每条都挂着巨大的 organic_tracking_token），整包过桥要 800KB+、原生再 JSON.parse
 * 一次 —— 实测就是卡在那一步（桥回来了、映射却不出结果）。这里在页面侧抽干，
 * 只回十几个字段，脚本本身也不到 2KB（脚本体积在实机上是个坑，见 README）。
 */
export function profileHeaderScript(cfgJson: string): string {
  const cfgLiteral: string = JSON.stringify(cfgJson);
  return '(async function(){try{' +
    'var CFG=JSON.parse(' + cfgLiteral + ');' +
    'var headers={};var hs=CFG.h||[];' +
    'for(var h=0;h<hs.length;h++){headers[hs[h][0]]=hs[h][1];}' +
    'var res=await fetch(String(CFG.u||""),{method:String(CFG.m||"POST"),credentials:"include",' +
    'headers:headers,body:(CFG.b||undefined)});' +
    'var t=await res.text();var j=null;try{j=JSON.parse(t);}catch(e){}' +
    'if(!j)return JSON.stringify({state:"non-json",http:res.status,len:t.length});' +
    'var u=(j.data&&j.data.user)?j.data.user:null;' +
    'if(!u)return JSON.stringify({state:"no-user"});' +
    'var hd=(u.hd_profile_pic_url_info&&u.hd_profile_pic_url_info.url)?u.hd_profile_pic_url_info.url:"";' +
    'return JSON.stringify({state:"ok",' +
    'username:String(u.username||""),fullName:String(u.full_name||""),bio:String(u.biography||""),' +
    'link:String(u.external_url||""),avatar:hd||String(u.profile_pic_url||""),' +
    'verified:u.is_verified===true,isPrivate:u.is_private===true,' +
    'followers:u.follower_count||0,following:u.following_count||0,posts:u.media_count||0});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,140)});}})()';
}

/**
 * 「我的」帖子网格：用存下来的模板回放一次，只回**每条的封面/宽高/是否视频/计数 + 游标**。
 *
 * 变量合并是**精简版**（只认 GraphQL 那种 `variables=<urlencoded json>` 的表单体）：
 * 引用共用的大助手包会把脚本撑到 5KB+，而注入脚本在实机上有体积坑。
 */
export function profilePostsScript(cfgJson: string, varsJson: string): string {
  const cfgLiteral: string = JSON.stringify(cfgJson);
  const varsLiteral: string = JSON.stringify(varsJson);
  return '(async function(){try{' +
    'var CFG=JSON.parse(' + cfgLiteral + ');var VARS=JSON.parse(' + varsLiteral + ');' +
    'var headers={};var hs=CFG.h||[];' +
    'for(var h=0;h<hs.length;h++){headers[hs[h][0]]=hs[h][1];}' +
    'var body=String(CFG.b||"");' +
    // 变量合并前后各留一份用于诊断：变量**类型**对不上时服务端只会回一句
    // noncoercible_variable_value（实测踩过：界面一片空白、日志里只有这一句），
    // 必须能对比"我们发了什么"和"页面原来发的是什么"才知道是哪个键被改坏了。
    'var varsOf=function(b){try{var m=String(b||"").match(/variables=([^&]*)/);' +
    'return m?decodeURIComponent(m[1]):"";}catch(e){return "";}};' +
    'var origVars=varsOf(body);' +
    'if(body.length>0&&VARS){try{' +
    'var parts=body.split("&");' +
    'for(var i=0;i<parts.length;i++){' +
    'if(parts[i].indexOf("variables=")!==0)continue;' +
    'var o=JSON.parse(decodeURIComponent(parts[i].substring(10)));' +
    'var ks=Object.keys(VARS);' +
    'for(var k=0;k<ks.length;k++){var key=ks[k];' +
    'if(VARS[key]===null){delete o[key];}else{o[key]=VARS[key];}}' +
    'parts[i]="variables="+encodeURIComponent(JSON.stringify(o));' +
    'body=parts.join("&");break;}}catch(e){}}' +
    'var sentVars=varsOf(body);' +
    'var res=await fetch(String(CFG.u||""),{method:String(CFG.m||"POST"),credentials:"include",' +
    'headers:headers,body:(body.length>0?body:undefined)});' +
    'var t=await res.text();var j=null;try{j=JSON.parse(t);}catch(e){}' +
    'if(!j)return JSON.stringify({state:"non-json",http:res.status,len:t.length,' +
    'head:String(t||"").slice(0,180)});' +
    // 连接节点的字段名不能写死：IG 时不时改名（user_timeline_graphql_connection 只是其中一种），
    // 写死的结果就是重放明明成功、界面却一个格子都没有（raw={"state":"no-conn","keys":""}）。
    // 这里先按名字找，找不到就在 data 里找第一个带 edges 的对象，并把它叫什么名字回报上来。
    'var d=j.data||{};' +
    'var c=d["xdt_api__v1__feed__user_timeline_graphql_connection"]||null;var ckey="timeline";' +
    'if(!c){for(var kk in d){var vv=d[kk];' +
    'if(vv&&typeof vv==="object"&&vv.edges){c=vv;ckey=String(kk);break;}}}' +
    'if(!c)return JSON.stringify({state:"no-conn",sent:sentVars.slice(0,240),' +
    'orig:origVars.slice(0,240),keys:Object.keys(d).slice(0,6).join(","),' +
    'err:(j.errors&&j.errors.length)?String(j.errors[0].message||"").slice(0,120):"",' +
    'msg:String(j.message||"").slice(0,60),status:String(j.status||""),http:res.status,' +
    'len:t.length,body:body.slice(0,240)});' +
    'var out=[];var es=c.edges||[];' +
    'for(var e=0;e<es.length;e++){' +
    'var n=es[e]?es[e].node:null;if(!n)continue;' +
    'var vv=n.video_versions||[];' +
    'var cand=(n.image_versions2&&n.image_versions2.candidates)||[];' +
    'var cover=vv.length?String(vv[0].url||""):(cand.length?String(cand[0].url||""):"");' +
    'var w=n.original_width||(cand.length?(cand[0].width||0):0);' +
    'var hh=n.original_height||(cand.length?(cand[0].height||0):0);' +
    'if(cover.length===0&&n.carousel_media&&n.carousel_media.length>0){' +
    'var c0=n.carousel_media[0];var cc=(c0.image_versions2&&c0.image_versions2.candidates)||[];' +
    'if(cc.length>0){cover=String(cc[0].url||"");w=c0.original_width||cc[0].width||0;' +
    'hh=c0.original_height||cc[0].height||0;}}' +
    'out.push({code:String(n.code||""),video:vv.length>0,cover:cover,w:w,h:hh,' +
    'likes:n.like_count||0,comments:n.comment_count||0});}' +
    'var pi=c.page_info||{};' +
    'return JSON.stringify({state:"ok",items:out,cursor:String(pi.end_cursor||""),' +
    'more:pi.has_next_page===true,count:c.count||0});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,140)});}})()';
}

/**
 * 在网页的搜索框里打字。
 *
 * 为什么要"驱动网页"而不是原生直接发搜索请求：IG 的搜索接口（doc_id / variables 形状）只有在
 * 页面**真的搜过一次**之后才会出现在 `window.__ogReplay` 里；我们先把这一发打出去，网络钩子
 * 记下模板，之后就能用存下来的模板回放任意关键词（见 searchResultsScript）。
 *
 * React 的受控输入框必须走原生 setter + input 事件，直接赋值 `el.value` 页面是收不到的
 * （React 自己维护 value 的跟踪器）——这是这套 UI 里最容易踩的一个坑。
 */
export function searchTypeScript(query: string): string {
  const queryLiteral: string = JSON.stringify(query);
  return '(function(){try{' +
    'var Q=' + queryLiteral + ';' +
    'var pick=function(){var sels=["input[name=\\"query\\"]","input[type=\\"search\\"]",' +
    '"input[type=\\"text\\"]","input[role=\\"searchbox\\"]","input[aria-label]"];' +
    'for(var i=0;i<sels.length;i++){var list=document.querySelectorAll(sels[i]);' +
    'for(var j=0;j<list.length;j++){var e=list[j];try{var r=e.getBoundingClientRect();' +
    'if(r.width>40&&r.height>12)return e;}catch(err){}}}return null;};' +
    'var el=pick();' +
    // 找不到输入框：先把搜索入口点开（有的版本搜索框在一个弹层里，要先点放大镜/搜索链接），
    // 让原生侧再试一次（见 SearchViewModel.ensureTemplate）。返回 "clicked-search" 表示"点了、再试"。
    'if(!el){try{var links=document.querySelectorAll(\'a[href*="/explore/search"],a[href*="search"]\');' +
    'for(var li=0;li<links.length;li++){var le=links[li];var lr=le.getBoundingClientRect();' +
    'if(lr.width>0&&lr.height>0){le.click();return "clicked-search";}}}catch(e){}' +
    'try{var ic=document.querySelectorAll(\'svg[aria-label="Search"]\');' +
    'if(ic.length>0){ic[0].dispatchEvent(new MouseEvent("click",{bubbles:true}));' +
    'return "clicked-search";}}catch(e){}' +
    'return "no-input";}' +
    'try{el.focus();}catch(e){}' +
    'try{var setter=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,"value").set;' +
    'setter.call(el,Q);}catch(e){try{el.value=Q;}catch(e2){}}' +
    'try{el.dispatchEvent(new Event("input",{bubbles:true}));}catch(e){}' +
    'try{el.dispatchEvent(new Event("change",{bubbles:true}));}catch(e){}' +
    // 有些实现要按一次回车才发请求；typeahead 那类则靠上面的 input 事件就够了。
    'try{el.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",code:"Enter",' +
    'keyCode:13,which:13,bubbles:true}));}catch(e){}' +
    'try{var f=el.form||(el.closest?el.closest("form"):null);' +
    'if(f)f.dispatchEvent(new Event("submit",{bubbles:true,cancelable:true}));}catch(e){}' +
    'try{el.dispatchEvent(new KeyboardEvent("keyup",{key:"Enter",code:"Enter",' +
    'keyCode:13,which:13,bubbles:true}));}catch(e){}' +
    'return "typed:"+String(el.name||el.type||"?");' +
    '}catch(e){return "err:"+String(e).slice(0,100);}})()';
}

/**
 * 搜索：用存下来的模板回放一次，把响应里**像用户的对象**扫出来。
 *
 * 刻意不写死路径：IG 搜索的响应结构换过好几版（`xdt_api__v1__fbsearch__topsearch_combined` /
 * `...__accounts` / 各种 `search_results`），写死一个键就是"换个版本就一片空白"。这里改成在整包
 * JSON 里按**形状**找：有 username、并且带 profile_pic_url 或 full_name 的对象就是一个用户。
 */
export function searchResultsScript(cfgJson: string, varsJson: string): string {
  const cfgLiteral: string = JSON.stringify(cfgJson);
  const varsLiteral: string = JSON.stringify(varsJson);
  return '(async function(){try{' +
    'var CFG=JSON.parse(' + cfgLiteral + ');var VARS=JSON.parse(' + varsLiteral + ');' +
    'var headers={};var hs=CFG.h||[];' +
    'for(var h=0;h<hs.length;h++){headers[hs[h][0]]=hs[h][1];}' +
    'var body=String(CFG.b||"");' +
    // 变量覆盖：**不靠键名**。查词那个键各版本叫法不同（query / search_query / q / ...），
    // 写死一个名字就会出现"换了关键词、结果还是上一个"（实测踩过）。这里按**值**改：
    // 把 values 里等于上一次查词的字符串、以及名字像查词的键，统一改成新词。
    'var hits=0;' +
    'if(body.length>0&&VARS){try{' +
    'var parts=body.split("&");' +
    'for(var i=0;i<parts.length;i++){' +
    'if(parts[i].indexOf("variables=")!==0)continue;' +
    'var o=JSON.parse(decodeURIComponent(parts[i].substring(10)));' +
    'var FROM=String(VARS.__ogFrom||"");var TO=String(VARS.__ogTo||"");' +
    'var NAMES=["query","search_query","q","search_term","term","keyword"];' +
    'var patch=function(node){' +
    'if(!node||typeof node!=="object")return;' +
    'for(var k in node){var v=node[k];' +
    'if(typeof v==="string"){' +
    'if(FROM.length>0&&v===FROM){node[k]=TO;hits++;}' +
    'else if(NAMES.indexOf(String(k).toLowerCase())>=0&&TO.length>0){node[k]=TO;hits++;}}' +
    'else if(v&&typeof v==="object"){patch(v);}}};' +
    'patch(o);' +
    'parts[i]="variables="+encodeURIComponent(JSON.stringify(o));' +
    'body=parts.join("&");break;}}catch(e){}}' +
    'var res=await fetch(String(CFG.u||""),{method:String(CFG.m||"POST"),credentials:"include",' +
    'headers:headers,body:(body.length>0?body:undefined)});' +
    'var t=await res.text();var j=null;try{j=JSON.parse(t);}catch(e){}' +
    'if(!j)return JSON.stringify({state:"non-json",http:res.status,len:t.length});' +
    'var seen={};var out=[];' +
    'var walk=function(o,depth){' +
    'if(!o||typeof o!=="object"||depth>8)return;' +
    'if(Object.prototype.toString.call(o)==="[object Array]"){' +
    'for(var i=0;i<o.length;i++)walk(o[i],depth+1);return;}' +
    'var un=o.username;' +
    'if(typeof un==="string"&&un.length>0&&out.length<40&&' +
    '(typeof o.profile_pic_url==="string"||typeof o.full_name==="string")){' +
    'if(!seen[un]){seen[un]=1;' +
    'var av=String(o.profile_pic_url||"");' +
    'try{if(o.hd_profile_pic_url_info&&o.hd_profile_pic_url_info.url){' +
    'av=String(o.hd_profile_pic_url_info.url);}}catch(e){}' +
    'out.push({u:un,name:String(o.full_name||""),avatar:av,' +
    'verified:o.is_verified===true,priv:o.is_private===true});}}' +
    'for(var k in o){var v=o[k];if(v&&typeof v==="object")walk(v,depth+1);}};' +
    'walk(j,0);' +
    'return JSON.stringify({state:"ok",items:out,count:out.length,hits:hits,' +
    'err:(j.errors&&j.errors.length)?String(j.errors[0].message||"").slice(0,120):""});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,140)});}})()';
}

/**
 * Reels 视频流：用存下来的模板回放一次，只回**每条要用的字段**（视频地址/封面/作者/游标）。
 *
 * 结构（实机结构摘要确认过）：`.data.xdt_api__v1__clips__home__connection_v2.edges[].node.media`，
 * 视频地址在 `video_versions[].url`，封面在 `image_versions2.candidates[]`，
 * 作者在 `media.user`，音乐在 `clips_metadata.original_sound_info`。
 *
 * 和「我的」那两条一样：**脚本要小**、只回十几个字段（整包响应几十上百 KB，
 * 过桥 + 原生解析不划算，见 README 里脚本体积那段）。
 */
export function reelsScript(cfgJson: string, varsJson: string): string {
  const cfgLiteral: string = JSON.stringify(cfgJson);
  const varsLiteral: string = JSON.stringify(varsJson);
  return '(async function(){try{' +
    'var CFG=JSON.parse(' + cfgLiteral + ');var VARS=JSON.parse(' + varsLiteral + ');' +
    'var headers={};var hs=CFG.h||[];' +
    'for(var h=0;h<hs.length;h++){headers[hs[h][0]]=hs[h][1];}' +
    'var body=String(CFG.b||"");' +
    // 变量合并前后各留一份用于诊断：变量**类型**对不上时服务端只会回一句
    // noncoercible_variable_value（实测踩过：界面一片空白、日志里只有这一句），
    // 必须能对比"我们发了什么"和"页面原来发的是什么"才知道是哪个键被改坏了。
    'var varsOf=function(b){try{var m=String(b||"").match(/variables=([^&]*)/);' +
    'return m?decodeURIComponent(m[1]):"";}catch(e){return "";}};' +
    'var origVars=varsOf(body);' +
    'if(body.length>0&&VARS){try{' +
    'var parts=body.split("&");' +
    'for(var i=0;i<parts.length;i++){' +
    'if(parts[i].indexOf("variables=")!==0)continue;' +
    'var o=JSON.parse(decodeURIComponent(parts[i].substring(10)));' +
    'var ks=Object.keys(VARS);' +
    'for(var k=0;k<ks.length;k++){var key=ks[k];' +
    'if(VARS[key]===null){delete o[key];}else{o[key]=VARS[key];}}' +
    'parts[i]="variables="+encodeURIComponent(JSON.stringify(o));' +
    'body=parts.join("&");break;}}catch(e){}}' +
    'var sentVars=varsOf(body);' +
    // ---- 快路径：页面自己那条 Clips 请求的响应已经在内存里（见 NETWORK_WATCHER 的 capture），
    // 直接用它，不再回放一次（省一次完整往返）。游标对不上才自己发。
    'var t="";var http=200;var src="replay";' +
    'var wantAfter="";try{var wv=JSON.parse(' + varsLiteral + ');' +
    'wantAfter=(wv&&wv.after)?String(wv.after):"";}catch(e){}' +
    'try{var cap=(window.__ogCap||{}).reels;' +
    'if(cap&&String(cap.t||"").length>0){' +
    'var gotAfter="";try{var cm2=String(cap.b||"").match(/variables=([^&]*)/);' +
    'if(cm2){var vo=JSON.parse(decodeURIComponent(cm2[1]));' +
    'gotAfter=(vo&&vo.after)?String(vo.after):"";}}catch(e){}' +
    'if(gotAfter===wantAfter){t=String(cap.t);src="capture";' +
    'try{delete window.__ogCap.reels;}catch(e){}}}}catch(e){}' +
    'if(t.length===0){' +
    'var res=await fetch(String(CFG.u||""),{method:String(CFG.m||"POST"),credentials:"include",' +
    'headers:headers,body:(body.length>0?body:undefined)});' +
    'http=res.status;t=await res.text();}' +
    'var j=null;try{j=JSON.parse(t);}catch(e){}' +
    'if(!j)return JSON.stringify({state:"non-json",http:http,len:t.length,src:src});' +
    'var c=(j.data&&j.data["xdt_api__v1__clips__home__connection_v2"])||null;' +
    'if(!c)return JSON.stringify({state:"no-conn",src:src,keys:(j.data?Object.keys(j.data).slice(0,4):[]).join(",")});' +
    'var out=[];var es=c.edges||[];' +
    MEDIA_PICK_JS +
    'for(var e=0;e<es.length;e++){' +
    'var n=es[e]?es[e].node:null;var m=n?n.media:null;' +
    'if(!m)continue;' +
    'var pickV=pickVideo(m,false);var pickVo=pickVideo(m,true);' +
    'var pickC=pickImage(m.image_versions2,false);var pickCo=pickImage(m.image_versions2,true);' +
    'var u=m.user||{};' +
    'var cm=m.clips_metadata||{};' +
    'var snd=cm.original_sound_info||{};' +
    'out.push({' +
    'code:String(m.code||""),' +
    // 媒体数字 id：Reels 页补视频地址、点赞/转发都用它（见 model/Reel 的 mediaId）。
    'id:String(m.pk||m.id||""),' +
    'url:pickV.url,' +
    'cover:pickC.url,' +
    // 下载用的原始地址（最大的一档）：展示用的那份已按 MEDIA_PICK_JS 降到 1080 档。
    'origUrl:pickVo.url,' +
    'origCover:pickCo.url,' +
    'w:m.original_width||0,h:m.original_height||0,' +
    'author:String(u.username||""),avatar:String(u.profile_pic_url||""),' +
    // 作者 pk：Reels 页那颗关注按钮要用（见 model/Reel 的 authorId）。
    'uid:String(u.pk||u.id||""),' +
    'verified:u.is_verified===true,' +
    'music:String(snd.original_audio_title||""),' +
    // 正文（Reels 页作者行下面那一段）。和音乐名分开：以前正文被塞进 music 那一栏。
    'caption:String((m.caption&&m.caption.text)||""),' +
    'liked:m.has_liked===true||m.viewer_has_liked===true,' +
    // 关注状态（Reels 页作者行那颗按钮）：网页载荷里它挂在 `user.friendship_status`。
    // 没有这个字段时**不给这个键**（undefined）——原生据此知道"要单独问一次"（见 model/Reel）。
    'following:(u.friendship_status&&(u.friendship_status.following!==undefined' +
    '?u.friendship_status.following===true' +
    ':(u.friendship_status.followed_by_viewer!==undefined' +
    '?u.friendship_status.followed_by_viewer===true:undefined))),' +
    // 转发数（动作区那颗转发下面的数字）。
    'reposts:m.media_repost_count||0,' +
    'likes:m.like_count||0,comments:m.comment_count||0,' +
    'plays:m.play_count||m.ig_play_count||0});}' +
    'var pi=c.page_info||{};' +
    'return JSON.stringify({state:"ok",src:src,items:out,cursor:String(pi.end_cursor||""),' +
    'more:pi.has_next_page===true,count:c.count||0});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,140)});}})()';
}

/**
 * 私信收件箱：用存下来的模板回放一次，只回**会话列表要用的那十几个字段**。
 *
 * 结构（实机结构摘要确认过，操作名 PolarisDirectInboxMobileQuery）：
 *   `.data.get_slide_mailbox_for_iris_subscription.threads_by_folder.edges[].node.as_ig_direct_thread`
 * 每个会话里：users / usersWithoutViewer（1:1 用对方的用户名与头像）、thread_title（群聊标题）、
 * slide_messages.edges[]（最近几条消息，取第一条当预览）、last_activity_timestamp_ms、
 * marked_as_unread / is_muted / is_pin。
 *
 * 和「我的」那两条一样：**脚本要小**、只回必要字段（整包响应几百 KB，过桥 + 原生解析不划算）；
 * 变量覆盖也**必须** `JSON.parse` 之后再合并（不 parse 就会把 variables 写成 {"0":"{",...}，
 * 服务端回 noncoercible_variable_value —— 这个坑在「我的」上踩过）。
 */
export function directInboxScript(cfgJson: string, varsJson: string): string {
  const cfgLiteral: string = JSON.stringify(cfgJson);
  const varsLiteral: string = JSON.stringify(varsJson);
  return '(async function(){try{' +
    'var CFG=JSON.parse(' + cfgLiteral + ');var VARS=JSON.parse(' + varsLiteral + ');' +
    'var headers={};var hs=CFG.h||[];' +
    'for(var h=0;h<hs.length;h++){headers[hs[h][0]]=hs[h][1];}' +
    'var body=String(CFG.b||"");' +
    'if(body.length>0&&VARS){try{' +
    'var parts=body.split("&");' +
    'for(var i=0;i<parts.length;i++){' +
    'if(parts[i].indexOf("variables=")!==0)continue;' +
    'var o=JSON.parse(decodeURIComponent(parts[i].substring(10)));' +
    'var ks=Object.keys(VARS);' +
    'for(var k=0;k<ks.length;k++){var key=ks[k];' +
    'if(VARS[key]===null){delete o[key];}else{o[key]=VARS[key];}}' +
    'parts[i]="variables="+encodeURIComponent(JSON.stringify(o));' +
    'body=parts.join("&");break;}}catch(e){}}' +
    'var res=await fetch(String(CFG.u||""),{method:String(CFG.m||"POST"),credentials:"include",' +
    'headers:headers,body:(body.length>0?body:undefined)});' +
    'var t=await res.text();var j=null;try{j=JSON.parse(t);}catch(e){}' +
    'if(!j)return JSON.stringify({state:"non-json",http:res.status,len:t.length});' +
    // 这条连接的字段名同样不写死：在 data 里找第一个带 threads_by_folder 的对象。
    'var d=j.data||{};var box=null;' +
    'for(var b in d){var v=d[b];if(v&&typeof v==="object"&&v.threads_by_folder){box=v;break;}}' +
    'if(!box)return JSON.stringify({state:"no-box",keys:Object.keys(d).slice(0,6).join(","),' +
    'err:(j.errors&&j.errors.length)?String(j.errors[0].message||"").slice(0,120):""});' +
    'var tf=box.threads_by_folder||{};var es=tf.edges||[];var out=[];' +
    'for(var e=0;e<es.length;e++){' +
    'var nd=es[e]?es[e].node:null;var th=(nd&&nd.as_ig_direct_thread)?nd.as_ig_direct_thread:nd;' +
    'if(!th)continue;' +
    'var us=th.usersWithoutViewer||th.users||[];var u=us.length>0?us[0]:null;' +
    'var ms=(th.slide_messages&&th.slide_messages.edges)?th.slide_messages.edges:[];' +
    'var m=ms.length>0?(ms[0].node||null):null;' +
    'var av="";if(u){av=String(u.profile_pic_url||"");' +
    'try{if(u.hd_profile_pic_url_info&&u.hd_profile_pic_url_info.url){' +
    'av=String(u.hd_profile_pic_url_info.url);}}catch(e){}}' +
    'var title=String(((u&&u.username)?u.username:(th.thread_title||"")));' +
    'if(title==="Empty")title=String((u&&u.username)?u.username:"");' +
    'out.push({id:String(th.thread_id||""),key:String(th.thread_key||""),' +
    'title:title,avatar:av,group:th.is_group===true,' +
    'unread:th.marked_as_unread===true,muted:th.is_muted===true,pinned:th.is_pin===true,' +
    'ts:Number(th.last_activity_timestamp_ms)||0,' +
    'text:(m?String(m.text||""):""),kind:(m?String(m.item_type||""):""),items:ms.length});}' +
    'var pi=tf.page_info||{};' +
    'return JSON.stringify({state:"ok",items:out,cursor:String(pi.end_cursor||""),' +
    'more:pi.has_next_page===true,count:out.length});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,140)});}})()';
}

/**
 * **会话详情探针**（诊断用）：在页面里同源 fetch 一次私信会话的私有 REST，回报结果。
 *
 * 为什么要在页面里 fetch：原生那条路（`NativeDirect.thread`）在真机上被 IG 回
 * `404 + not-logged-in`，而**同一个用户、同一个会话，网页自己打开是能看的**。差别只可能在
 * 请求头/来源（Referer、x-web-session-id…）或 cookie 上。这一发探针就是拿"页面自己的身份"
 * 去问一次同一个地址：
 *   - 页面里能通 → 会话详情改走**页面内 fetch**（和 directInboxScript 一样）就有解；
 *   - 页面里也 404 → 说明 IG 真的不给这条 REST 用，得换 Bloks 那条路。
 *
 * 只读，不改任何状态。
 */
export function directThreadProbeScript(threadId: string): string {
  const idLiteral: string = JSON.stringify(threadId);
  return '(async function(){try{' +
    'var ID=' + idLiteral + ';' +
    'var url="/api/v1/direct_v2/threads/"+ID+"/?limit=20";' +
    'var out={};' +
    // ① 只带 cookie（同源 fetch 默认带 credentials）+ 网页版 app id。
    'try{var r=await fetch(url,{credentials:"include",' +
    'headers:{"x-ig-app-id":"936619743392459"}});' +
    'var t=await r.text();' +
    'out.http=r.status;out.len=t.length;out.head=t.slice(0,160).replace(/[\\r\\n]+/g," ");' +
    'out.json=t.indexOf("{\\"")===0||t.indexOf("for(;;)")===0;' +
    '}catch(e){out.err=String(e).slice(0,120);}' +
    'out.href=location.href;' +
    'return JSON.stringify({state:"ok",probe:out});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,140)});}})()';
}

/**
 * **私信会话页"往上滚一屏"**（诊断用，见 DirectThreadViewModel.probePagingCursor）。
 *
 * 目的只有一个：让**页面自己**去翻一页历史 —— 它发出的那条 `IGDThreadDetailQuery` 里会带着
 * 真实的分页变量值（`min_uq_seq_id`）。我们手上的两种游标（不透明 end_cursor / `mid.$…`）
 * 喂进去都被 IG 忽略，只有看它自己填什么才能对。
 *
 * 找滚动容器：页面上 scrollHeight 与 clientHeight 差距最大的那个（消息流就是它）。
 */
export function directScrollUpScript(): string {
  return '(function(){try{' +
    'var best=null,bestGap=0;var all=document.querySelectorAll("div");' +
    'for(var i=0;i<all.length;i++){var e=all[i];' +
    'var gap=e.scrollHeight-e.clientHeight;' +
    'if(gap>bestGap&&e.clientHeight>200){bestGap=gap;best=e;}}' +
    'if(!best)return JSON.stringify({state:"no-scroll"});' +
    'var before=best.scrollTop;' +
    // 两个方向都试：真机上这个容器 scrollTop 本来就是 0（已在顶端），往负数滚等于没动；
    // 反过来滚到另一端才可能触发"加载更老"。
    'var target=(before<=0)?(best.scrollHeight-best.clientHeight):0;' +
    'best.scrollTop=target;' +
    'try{best.dispatchEvent(new Event("scroll",{bubbles:true}));}catch(e){}' +
    'try{best.dispatchEvent(new WheelEvent("wheel",{bubbles:true,deltaY:(target>before?600:-600)}));}catch(e){}' +
    'return JSON.stringify({state:"ok",before:before,after:best.scrollTop,gap:bestGap});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,120)});}})()';
}

/**
 * 用**原生存下来的评论模板**取评论（不导航、不等页面渲染）。
 *
 * 这是"回放"真正的落点：第一次打开评论走导航（顺带把模板存到原生），之后每次都用这里取
 * —— 一次 fetch 就回来，还能把 `first` 调大。解析复用页面上现成的评论收集器
 * （collectInto），所以原生侧不用另写一套 JSON 提取。
 */
export function commentsByStoredCfgScript(cfgJson: string, shortcode: string,
                                         mediaId: string, first: number): string {
  const cfgLiteral: string = JSON.stringify(cfgJson);
  const codeLiteral: string = JSON.stringify(shortcode);
  const mediaLiteral: string = JSON.stringify(mediaId);
  const count: number = first > 0 ? first : 50;
  return '(async function(){try{' +
    'var CFG=JSON.parse(' + cfgLiteral + ');var CODE=' + codeLiteral + ';' +
    'var MEDIA=' + mediaLiteral + ';var FIRST=' + count + ';' +
    SLEEP_JS +
    COMMENTS_JSON_JS +
    GRAPHQL_VARS_JS +
    // media_id 用帖子 id 里 `_` 前面那段；模板里是别的帖子的值也不怕，下面会覆盖。
    'var target={first:FIRST,after:null,last:null};' +
    'if(MEDIA.length>0)target.media_id=MEDIA;' +
    'if(CODE.length>0)target.shortcode=CODE;' +
    'var headers={};var hs=CFG.h||[];' +
    'for(var h=0;h<hs.length;h++){headers[hs[h][0]]=hs[h][1];}' +
    'var body=mergeVars(String(CFG.b||""),target);' +
    'body=body.replace(/__req=[^&]*/,"__req="+Math.random().toString(36).slice(2,4));' +
    'var t0=Date.now();var http=0;var out=[];var seen={};var keys=[];var src="stored";' +
    'try{' +
    'var ac=new AbortController();var tm=setTimeout(function(){ac.abort();},9000);' +
    'var res=await fetch(String(CFG.u||""),{method:String(CFG.m||"POST"),credentials:"include",' +
    'headers:headers,body:(body.length>0?body:undefined),signal:ac.signal});' +
    'clearTimeout(tm);if(res){http=res.status;var txt=await res.text();var json=null;' +
    'try{json=JSON.parse(txt);}catch(e){}' +
    'if(json)collectInto(json,out,seen,keys);else src="stored-nonjson";}' +
    '}catch(e){src="stored-error";}' +
    'return JSON.stringify({state:out.length>0?"ok":"empty",items:out,' +
    'diag:"src="+src+" http="+http+" ms="+(Date.now()-t0)+" n="+out.length+' +
    '+" keys="+keys.slice(0,4).join("|")});' +
    '}catch(e){return JSON.stringify({state:"error",message:String(e).slice(0,160)});}})()';
}
