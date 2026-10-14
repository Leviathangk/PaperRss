import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source=fs.readFileSync(new URL('../PaperRss/Sources/App/ArticleReaderView.swift',import.meta.url),'utf8');
const script=source.match(/static let observerScript = WKUserScript\(\s*source: """([\s\S]*?)""",\s*injectionTime:/)[1];
function fixture(offscreenNodes = 0) {
 const frames=[],messages=[],timers=new Map(),listeners=new Map(); let nextTimer=0,boundsReads=0;
 const node=(id,top)=>({dataset:{paperRssId:id},getBoundingClientRect:()=>{boundsReads++;return {top,bottom:top+200}}});
 const nodes=[node('p0',100),...Array.from({length:offscreenNodes},(_,i)=>node('p'+(i+1),2000+i*300))];
 const window={innerHeight:800,paperRssReaderInteractive:false,addEventListener(name,listener){listeners.set(name,listener)},webkit:{messageHandlers:{paperRssReaderScroll:{postMessage(){}},paperRssVisibleParagraphs:{postMessage(p){messages.push(p)}}}}};
 const document={querySelectorAll:()=>nodes,querySelector:q=>({content:q.includes('load-generation')?'7':'article-A'}),addEventListener(name,listener){listeners.set(name,listener)},documentElement:{scrollTop:0},body:{scrollTop:0}};
 const context=vm.createContext({window,document,requestAnimationFrame:f=>frames.push(f),setTimeout:f=>{timers.set(++nextTimer,f);return nextTimer},clearTimeout:id=>timers.delete(id),IntersectionObserver:class{observe(){}},Map});
 vm.runInContext(script,context);
 const flush=()=>{while(frames.length)frames.shift()()};
 const flushTimers=()=>{const pending=[...timers.values()];timers.clear();pending.forEach(f=>f())};
 return {window,messages,flush,flushTimers,listeners,reads:()=>boundsReads};
}
test('首屏早于原生就绪时，就绪握手仍能提交当前可见段落',()=>{
 const f=fixture(); f.flush(); assert.equal(f.messages.length,0);
 f.window.paperRssReaderInteractive=true;
 assert.equal(typeof f.window.paperRssRequestVisibleParagraphs,'function');
 f.window.paperRssRequestVisibleParagraphs(7); f.flush();
 assert.equal(f.messages.length,1); assert.deepEqual(Array.from(f.messages[0].paragraphIDs),['p0']);
 assert.equal(f.messages[0].generation,'7'); assert.equal(f.messages[0].documentIdentity,'article-A');
});
test('过期文档握手不会启动当前页面的翻译',()=>{
 const f=fixture();f.flush();f.window.paperRssReaderInteractive=true;
 f.window.paperRssRequestVisibleParagraphs(6);f.flush();assert.equal(f.messages.length,0);
});
test('两个平台都校验段落快照身份并在就绪时请求首屏快照',()=>{
 assert.equal((source.match(/identity == loadedDocumentIdentity, identity == parent.entry.id/g)||[]).length,2);
 assert.equal((source.match(/if \(becameInteractive\) window.paperRssRequestVisibleParagraphs/g)||[]).length,2);
});
test('首屏握手后布局刷新只测量预加载范围，不重复扫描长文',()=>{
 const f=fixture(1000);f.window.paperRssReaderInteractive=true;
 f.window.paperRssRequestVisibleParagraphs(7);f.flush();
 const before=f.reads(); f.listeners.get('paperRssLayoutRefresh')();f.flush();
 assert.equal(f.reads()-before,1);
 assert.equal(f.window.paperRssVisibleTranslationNodes.length,1);
});
test('连续滚动期间及时发布翻译范围，不等待手势结束',()=>{
 const f=fixture();f.window.paperRssReaderInteractive=true;
 f.listeners.get('scroll')();f.window.paperRssRequestVisibleParagraphs(7);f.flush();
 assert.equal(f.messages.length,1);assert.equal(f.window.paperRssReaderScrolling,true);
 f.flushTimers();f.flush();
 assert.equal(f.window.paperRssReaderScrolling,false);assert.equal(f.messages.length,1);
});
test('正文允许新可见段落入队但去重待处理段落，两个平台校验文档身份',()=>{
 assert.doesNotMatch(source,/pendingBilingualParagraphIDs\.isEmpty/);
 assert.match(source,/!pendingBilingualParagraphIDs\.contains\(\$0\)/);
 assert.equal((source.match(/"documentIdentity": identity/g)||[]).length,2);
});

const synchronizationScript = source.match(/static let translationSynchronizationScript = ReaderTranslationPresentation\.bootstrapScript \+ """([\s\S]*?)"""/)[1];
function translationFixture() {
 const frames=[],timers=[],created=[],events=[],scrolls=[];let scans=0;
 class Element {
  constructor(tag) {
   this.tagName=tag.toUpperCase();this.children=[];this.dataset={};this.attributes={};this.connected=false;
   this.classList={toggle:(name,on)=>{this.attributes[name]=on},contains:name=>!!this.attributes[name]};
  }
  append(...children){this.children.push(...children)}
  appendChild(child){this.append(child)}
  setAttribute(name,value){this.attributes[name]=value}
  removeAttribute(name){delete this.attributes[name]}
  querySelector(selector){return this.children.find(child=>'.'+child.className===selector)||this.children.flatMap(child=>child.querySelector(selector)||[])[0]}
  insertAdjacentElement(placement,aside){aside.connected=true;events.push('write:'+this.dataset.paperRssId);this.placement=placement}
  remove(){this.connected=false;events.push('remove:'+this.id)}
  getBoundingClientRect(){events.push('bounds:'+this.dataset.paperRssId);return {top:200,bottom:400}}
 }
 const sources=new Map(['p0','p1'].map(id=>{const node=new Element('p');node.dataset.paperRssId=id;return [id,node]}));
 const document={
  documentElement:{dataset:{paperTranslationMode:'replacement'}},
  querySelectorAll(){scans++;return [...sources.values()]},
  querySelector(selector){
   if(selector.includes('load-generation'))return {content:'7'};
   if(selector.includes('document-identity'))return {content:'article-A'};
   return sources.get(selector.match(/data-paper-rss-id="([^"]+)"/)?.[1]);
  },
  getElementById:id=>created.find(node=>node.id===id&&node.connected),
  createElement(tag){const node=new Element(tag);created.push(node);return node}
 };
 const window={innerHeight:800,paperRssReaderScrolling:false,paperRssVisibleTranslationNodes:[sources.get('p0')],
  paperRssTranslationPresentation:{measure:id=>{events.push('measure:'+id);return {}},reconcile:id=>events.push('reconcile:'+id),remove:id=>events.push('unwrap:'+id)},
  dispatchEvent:event=>events.push('event:'+event.type),scrollBy:value=>scrolls.push(value)};
 const context=vm.createContext({window,document,Map,CSS:{escape:value=>value},Event:class{constructor(type){this.type=type}},requestAnimationFrame:f=>{frames.push(f);return frames.length},cancelAnimationFrame:id=>{frames[id-1]=null},setTimeout:f=>{timers.push(f);return timers.length},clearTimeout:id=>{timers[id-1]=null}});
 const queue=(updates,removals=[],generation=7,documentIdentity='article-A')=>{
  Object.assign(context,{updates,removals,generation,documentIdentity});vm.runInContext(synchronizationScript,context);
 };
 const flush=()=>{const pending=frames.slice();frames.fill(null);pending.forEach(f=>f?.())};
 return {queue,flush,window,document,events,scrolls,scans:()=>scans,flushTimers:()=>{const pending=timers.slice();timers.fill(null);pending.forEach(f=>f?.())}};
}
test('同一帧的占位与完成消息合并，只执行最终译文并统一读写布局',()=>{
 const f=translationFixture();
 f.queue([{id:'p0',text:'loading',isLoading:true}]);
 f.queue([{id:'p0',text:'最终译文',isLoading:false},{id:'p1',text:'第二段',isLoading:false}]);
 assert.equal(f.document.getElementById('paper-rss-translation-p0'),undefined);
 f.flush();
 assert.equal(f.document.getElementById('paper-rss-translation-p0').querySelector('.paper-rss-translation-text').textContent,'最终译文');
 assert.equal(f.events.filter(e=>e.startsWith('event:')).length,1);
 assert.equal(f.scans(),0,'更新译文不扫描全文');
 const firstWrite=f.events.findIndex(e=>e.startsWith('write:'));
 assert.ok(f.events.lastIndexOf('measure:p1')<firstWrite,'先读取所有排版，再统一写 DOM');
});
test('滚动中已完成译文立即显示，未改变锚点高度则不调整滚动',()=>{
 const f=translationFixture();f.window.paperRssReaderScrolling=true;
 f.queue([{id:'p0',text:'译文',isLoading:false}]);f.flush();
 assert.ok(f.document.getElementById('paper-rss-translation-p0'));assert.equal(f.scrolls.length,0);
 assert.equal(f.events.filter(e=>e.startsWith('bounds:')).length,3);
 f.window.paperRssReaderScrolling=false;f.flushTimers();f.flush();
 assert.ok(f.document.getElementById('paper-rss-translation-p0'));
});
test('待插入的译文被撤回后不会残留，过期文章消息不修改当前文档',()=>{
 const f=translationFixture();f.queue([{id:'p0',text:'过期',isLoading:false}]);f.queue([],['p0']);f.flush();
 assert.equal(f.document.getElementById('paper-rss-translation-p0'),undefined);
 f.queue([{id:'p0',text:'错文档',isLoading:false}],[],6,'article-A');
 f.queue([{id:'p0',text:'错文档',isLoading:false}],[],7,'article-B');f.flush();
 assert.equal(f.document.getElementById('paper-rss-translation-p0'),undefined);
});
test('不可见 WebKit 暂停动画帧时，定时兜底仍提交结果，后续帧不重复布局',()=>{
 const f=translationFixture();f.queue([{id:'p0',text:'后台完成',isLoading:false}]);
 f.flushTimers();assert.ok(f.document.getElementById('paper-rss-translation-p0'));
 f.flush();assert.equal(f.events.filter(e=>e.startsWith('event:')).length,1);
});
