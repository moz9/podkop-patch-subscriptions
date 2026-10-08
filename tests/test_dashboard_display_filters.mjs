import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import test from 'node:test';

const source = fs.readFileSync(new URL('../openwrt/main.js', import.meta.url), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));
const nodes = value => value && typeof value === 'object'
  ? [value, ...[value.children].flat(Infinity).flatMap(nodes)] : [];
const labels = value => nodes(value).filter(node => node.tag === 'b').map(node => node.children);
function load(context, name, text = source) {
  const match = text.match(new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n|$)`));
  assert.ok(match, `${name} implements the dashboard display filters`);
  vm.runInContext(match[0], context);
}
function harness() {
  const stored = new Map();
  const context = vm.createContext({
    _: text => text, E: (tag, attrs, children) => ({tag, attrs, children}), structuredClone,
    localStorage: {getItem: key => stored.get(key), setItem: (key, value) => stored.set(key, value)},
  });
  return {context, stored};
}
const filters = {hideUnavailable:true, hideSlow:true, maxLatency:1000};
const section = {code:'main-out', displayName:'main', withTagSelect:true, outbounds:[
  {code:'fast', displayName:'fast', latency:80, latencyState:'available'},
  {code:'slow', displayName:'slow', latency:2000, latencyState:'available'},
  {code:'unknown', displayName:'unknown', latency:0, latencyState:'unknown'},
  {code:'offline', displayName:'offline', latency:0, latencyState:'unavailable'},
  {code:'selected', displayName:'selected', selected:true, latency:2500, latencyState:'available'},
  {code:'auto', displayName:'Fastest', isGroup:true, latency:3000, latencyState:'available'},
]};

test('display filters hide slow/offline nodes while preserving selected, group and unknown', () => {
  const {context} = harness();
  if (source.includes('function isDashboardOutboundVisible(')) load(context, 'isDashboardOutboundVisible');
  load(context, 'renderDefaultState');
  const before = JSON.stringify(section);
  const rendered = context.renderDefaultState({section, displayFilters:filters});
  assert.deepEqual(labels(rendered), ['fast','unknown','selected','Fastest']);
  assert.equal(JSON.stringify(section), before, 'display filtering never changes original candidates');
  assert.match(JSON.stringify(rendered), /Показано: 4 из 6/);
  const empty = context.renderDefaultState({section:{...section,outbounds:[section.outbounds[1]]},displayFilters:filters});
  assert.match(JSON.stringify(empty), /Все узлы скрыты фильтрами/);
  const fixed = context.renderDefaultState({section:{...section,withTagSelect:false,canTestLatency:false},displayFilters:filters});
  assert.equal(labels(fixed).length, 6, 'fixed and not-imported section remains visible');
  assert.ok(nodes(fixed).every(node => !Array.isArray(node.children) || !node.children.includes(null)), 'LuCI must not render literal null');
  assert.match(JSON.stringify(rendered), /Не проверен/);
  const offline = context.renderDefaultState({section:{...section,outbounds:[section.outbounds[3]]}});
  assert.match(JSON.stringify(offline), /Нет ответа/);
});

test('history retains tri-state instead of treating missing history as unavailable', () => {
  const {context} = harness();
  load(context,'getDashboardLatencyInfo');
  for (const [proxy,state,latency] of [
    [undefined,'unknown',0], [{history:[]},'unknown',0], [{history:[{delay:'bad'}]},'unknown',0],
    [{history:[{delay:0}]},'unavailable',0], [{history:[{delay:-1}]},'unavailable',0],
    [{alive:false,history:[{delay:100}]},'unavailable',0], [{history:[{delay:1200}]},'available',1200],
  ]) assert.deepEqual(plain(context.getDashboardLatencyInfo(proxy)), {latency,latencyState:state});
  load(context,'isDashboardOutboundVisible');
  assert.equal(context.isDashboardOutboundVisible({latency:1000},filters),true);
  assert.equal(context.isDashboardOutboundVisible({latency:1001},filters),false);
  assert.equal(context.isDashboardOutboundVisible({reason:'Unsupported protocol'},filters),false);
  assert.equal(context.isDashboardOutboundVisible({latency:1200},{...filters,maxLatency:NaN}),false);
  assert.equal(context.isDashboardOutboundVisible({latency:3000},{...filters,hideSlow:false}),true);
  assert.equal(context.isDashboardOutboundVisible({latencyState:'unavailable'},{...filters,hideUnavailable:false}),true);
});

test('controls validate integer milliseconds, persist across reload, and tolerate blocked storage', () => {
  const {context,stored} = harness();
  for (const name of ['loadDashboardDisplayFilters','saveDashboardDisplayFilters','renderDashboardFilters']) load(context,name);
  const changes=[];
  const panel=context.renderDashboardFilters(filters, patch=>changes.push(patch));
  const controls=nodes(panel).filter(node=>node.tag==='input');
  assert.deepEqual(controls.map(node=>node.attrs.type),['checkbox','checkbox','number']);
  controls[0].attrs.change({target:{checked:false}});
  controls[1].attrs.change({target:{checked:false}});
  let validity;
  const event = value => ({target:{value,setCustomValidity:value=>validity=value,reportValidity(){}}});
  controls[2].attrs.change(event('2000'));
  assert.deepEqual(plain(changes),[{hideUnavailable:false},{hideSlow:false},{maxLatency:2000}]);
  for (const value of ['', '0', '-1', '1.5', '60001', 'bad']) {
    controls[2].attrs.change(event(value));
    assert.notEqual(validity,'');
  }
  assert.equal(changes.length,3,'invalid values do not change threshold');
  controls[2].attrs.change(event('60000'));
  assert.equal(validity,'');
  context.saveDashboardDisplayFilters(filters);
  assert.deepEqual(plain(context.loadDashboardDisplayFilters()),filters);
  for (const value of ['null','{invalid','{"hideUnavailable":"true","maxLatency":0}']) {
    stored.set('podkop_dashboard_display_filters',value);
    assert.deepEqual(plain(context.loadDashboardDisplayFilters()),{hideUnavailable:false,hideSlow:false,maxLatency:1000});
  }
  context.localStorage={getItem(){throw new Error('disabled')},setItem(){throw new Error('disabled')}};
  assert.doesNotThrow(()=>context.loadDashboardDisplayFilters());
  assert.doesNotThrow(()=>context.saveDashboardDisplayFilters(filters));
});

test('all legacy dashboard mappings preserve latency state and original RPC response contract', async () => {
  const {context} = harness();
  if (source.includes('function getDashboardLatencyInfo(')) load(context,'getDashboardLatencyInfo');
  for(const name of ['normalizeProxyLinks','getSubscriptionSkippedReasonLabel','getDashboardSections']) load(context,name);
  const config=[
    {'.name':'url',connection_type:'proxy',proxy_config_type:'url',proxy_string:'vless://one#Single'},
    {'.name':'raw',connection_type:'proxy',proxy_config_type:'outbound',outbound_json:'{"tag":"Raw"}'},
    {'.name':'manual',connection_type:'proxy',proxy_config_type:'selector',selector_proxy_links:['vless://two#Manual']},
    {'.name':'pool',connection_type:'proxy',proxy_config_type:'urltest',urltest_proxy_links:['vless://three#Pool']},
    {'.name':'sub',connection_type:'proxy',proxy_config_type:'subscription_urltest',urltest_proxy_links:['vless://four#Static']},
    {'.name':'vpn',connection_type:'vpn',interface:'wg0'},
  ];
  const proxyMap={
    'url-out':{name:'url-out',type:'VLESS',history:[{delay:10}]},
    'raw-out':{name:'raw-out',type:'VLESS',history:[{delay:0}]},
    'manual-out':{name:'manual-out',type:'Selector',now:'manual-1-out'},
    'manual-1-out':{name:'manual-1-out',type:'VLESS',history:[]},
    'pool-out':{name:'pool-out',type:'Selector',now:'pool-urltest-out'},
    'pool-urltest-out':{name:'pool-urltest-out',type:'URLTest',now:'pool-node',all:['pool-node'],history:[{delay:9000}]},
    'pool-node':{name:'pool-node',type:'VLESS',history:[{delay:0}]},
    'sub-out':{name:'sub-out',type:'Selector',now:'sub-node'},
    'sub-urltest-out':{name:'sub-urltest-out',type:'URLTest',now:'sub-node',all:['sub-node','sub-cached'],history:[]},
    'sub-node':{name:'sub-node',type:'VLESS',history:[{delay:77}]},
    'sub-cached':{name:'sub-cached',type:'VLESS',alive:false,history:[{delay:30}]},
    'vpn-out':{name:'vpn-out',type:'WireGuard',history:[{delay:44}]},
  };
  context.getConfigSections=async()=>config;
  context.splitProxyString=value=>value ? value.split('\n') : [];
  context.getProxyUrlName=value=>value?.split('#')[1] || '';
  context.PodkopShellMethods={
    getClashApiProxies:async()=>({success:true,data:{proxies:proxyMap}}),
    getSubscriptionCachedLinks:async()=>({success:true,data:['vless://five#Cached']}),
    getSubscriptionSkippedLinks:async()=>({success:true,data:[{name:'Skipped',protocol:'vless',reason:'unsupported_transport'}]}),
  };
  const result=await context.getDashboardSections();
  assert.equal(result.success,true);
  assert.deepEqual(plain(result.data.slice(0,6).map(s=>s.outbounds.map(o=>o.latencyState))),[
    ['available'],['unavailable'],['unknown'],['available','unavailable'],['unknown','available','unavailable'],['available'],
  ]);
  assert.equal(result.data[3].outbounds[0].isGroup,true,'Fastest must not disappear even when slow or unavailable');
  assert.equal(result.data[3].activeCandidateCode,'pool-node','DNS active-candidate mapping retained');
  load(context,'isDashboardOutboundVisible');
  assert.equal(result.data[3].outbounds[1].selected,false,'automatic candidate is not marked manually selected');
  assert.equal(context.isDashboardOutboundVisible(result.data[3].outbounds[1],filters),true,'really active automatic candidate stays visible');
  assert.equal(result.data[4].outbounds[2].displayName,'Cached');
  assert.equal(result.data[6].canTestLatency,false);
  assert.equal(result.data[6].outbounds[0].reason,'Not supported');
  config[2].selector_proxy_links='vless://two#Manual';
  config[3].urltest_proxy_links='vless://three#Pool';
  const scalarLinks=await context.getDashboardSections();
  assert.equal(scalarLinks.data[2].outbounds[0].displayName,'Manual','string-form selector links have same mapping as list-form UCI');
  assert.equal(scalarLinks.data[3].outbounds[1].displayName,'Pool','string-form URLTest links retain candidate names');
  proxyMap['pool-out'].now='pool-node';
  const manualOverride=await context.getDashboardSections();
  assert.equal(manualOverride.data[3].outbounds[1].active,false,'automatic marker is off under manual override');
  assert.equal(manualOverride.data[3].outbounds[1].selected,true);
  proxyMap['pool-urltest-out'].all='pool-node';
  const malformed=await context.getDashboardSections();
  assert.equal(malformed.data[3].outbounds.length,1,'malformed URLTest all preserves group control without crashing');
  context.PodkopShellMethods.getClashApiProxies=async()=>({success:false,data:{}});
  assert.deepEqual(plain(await context.getDashboardSections()),{success:false,data:[]});
});

test('filter changes and refreshed history rerender through real StoreService without mutation RPC', async () => {
  const {context,stored} = harness();
  for(const name of ['loadDashboardDisplayFilters','saveDashboardDisplayFilters','isDashboardOutboundVisible','renderDashboardFilters','renderDefaultState','renderFailedState','renderLoadingState','renderSections','renderWidget','renderFailedState2','renderLoadingState2','renderDefaultState2','getDashboardLatencyInfo','normalizeProxyLinks','getSubscriptionSkippedReasonLabel','getDashboardSections']) load(context,name);
  const storeStart=source.indexOf('function jsonStableStringify(');
  const storeEnd=source.indexOf('// src/helpers/downloadAsTxt.ts',storeStart);
  context.initialDiagnosticStore={};
  vm.runInContext(source.slice(storeStart,storeEnd),context);
  const controller=source.slice(source.indexOf('// src/podkop/tabs/dashboard/initController.ts'),source.indexOf('// src/podkop/tabs/dashboard/styles.ts'));
  for(const name of ['onStoreUpdate','renderSectionsWidget','fetchDashboardSections','handleTestGroupLatency','handleTestProxyLatency','handleChooseOutbound']) load(context,name,controller);
  load(context,'render',source.slice(source.indexOf('// src/podkop/tabs/dashboard/render.ts'),source.indexOf('// src/helpers/prettyBytes.ts')));
  let rendered=[];
  context.document={getElementById:()=>({replaceChildren:(...children)=>rendered=children})};
  context.logger={debug(){},error(){}};
  context.preserveScrollForPage=fn=>fn();
  const mutationCalls=[];
  const probes=[];
  const codes=['main-fast','main-slow','main-unknown','main-offline','main-selected'];
  const proxyMap={
    'main-out':{name:'main-out',type:'Selector',now:'main-selected',all:['main-urltest-out',...codes]},
    'main-urltest-out':{name:'main-urltest-out',type:'URLTest',now:'main-fast',all:codes,history:[{delay:3000}]},
    'main-fast':{name:'fast',type:'VLESS',history:[{delay:80}]},
    'main-slow':{name:'slow',type:'VLESS',history:[{delay:2000}]},
    'main-unknown':{name:'unknown',type:'VLESS',history:[]},
    'main-offline':{name:'offline',type:'VLESS',history:[{delay:0}]},
    'main-selected':{name:'selected',type:'VLESS',history:[{delay:2500}]},
  };
  context.getConfigSections=async()=>[{'.name':'main',connection_type:'proxy',proxy_config_type:'urltest',urltest_proxy_links:[]}];
  context.getProxyUrlName=()=>'';
  context.uci=new Proxy({}, {get:(_target,key)=>()=>mutationCalls.push(['uci',key])});
  context.PodkopShellMethods={
    getClashApiProxies:async()=>({success:true,data:{proxies:proxyMap}}),
    setClashApiGroupProxy:(...args)=>mutationCalls.push(['select',...args]),
    getClashApiGroupLatency:async code=>{probes.push({code,all:structuredClone(proxyMap[code].all)});},
    getClashApiProxyLatency:async code=>{probes.push(code);},
  };
  context.CustomPodkopMethods={getDashboardSections:context.getDashboardSections};
  context.store.subscribe(context.onStoreUpdate);
  await context.fetchDashboardSections();
  assert.equal(labels({children:rendered}).length,6);
  const panel=nodes(context.render()).find(node=>node.attrs?.class==='pdk-dashboard-filters');
  assert.ok(panel,'dashboard render mounts the actual filter controls');
  const controls=nodes(panel).filter(node=>node.tag==='input');
  controls[0].attrs.change({target:{checked:true}});
  assert.deepEqual(labels({children:rendered}),['Fastest','fast','slow','unknown','selected']);
  controls[1].attrs.change({target:{checked:true}});
  assert.deepEqual(labels({children:rendered}),['Fastest','fast','unknown','selected']);
  controls[2].attrs.change({target:{value:'3000',setCustomValidity(){}}});
  assert.deepEqual(labels({children:rendered}),['Fastest','fast','slow','unknown','selected']);
  assert.equal(JSON.parse(stored.get('podkop_dashboard_display_filters')).maxLatency,3000);
  proxyMap['main-unknown'].history=[{delay:0}];
  proxyMap['main-slow'].history=[{delay:4000}];
  await context.fetchDashboardSections();
  assert.deepEqual(labels({children:rendered}),['Fastest','fast','selected'],'history update applies existing display preferences');
  assert.deepEqual(mutationCalls,[],'display preferences and rendering do not call UCI or selection RPC');
  const button=nodes({children:rendered}).find(node=>node.tag==='button');
  await button.attrs.click();
  assert.deepEqual(probes,[{code:'main-out',all:['main-urltest-out',...codes]}],'latency action probes complete original group including hidden nodes, not visible subset');
  assert.equal(context.store.get().sectionsWidget.data[0].outbounds.length,6);
  assert.deepEqual(mutationCalls,[]);
});

test('dashboard filter styles retain responsive controls and full-width empty message', () => {
  const styles=source.slice(source.indexOf('// src/podkop/tabs/dashboard/styles.ts'),source.indexOf('// src/podkop/tabs/dashboard/index.ts'));
  for(const selector of ['pdk-dashboard-filters','pdk-dashboard-filters__control','pdk-dashboard-filters__limit','pdk-dashboard-filters__hint','pdk-dashboard-filters__empty']) {
    assert.ok(styles.includes(`.${selector} {`),`${selector} needs dashboard stylesheet`);
  }
  assert.match(styles,/\.pdk-dashboard-filters \{[^}]*flex-wrap: wrap/);
  assert.match(styles,/\.pdk-dashboard-filters__empty \{[^}]*grid-column: 1 \/ -1/);
});
