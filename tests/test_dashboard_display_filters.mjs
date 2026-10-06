import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source = fs.readFileSync(new URL('../openwrt/main.js', import.meta.url), 'utf8');
const context = vm.createContext({
  _:text=>text,
  E:(tag,attrs,children)=>({tag,attrs,children}),
});
for (const name of ['getDashboardLatencyInfo','loadDashboardDisplayFilters','saveDashboardDisplayFilters','isDashboardOutboundVisible','renderDashboardFilters','renderDefaultState']) {
  const match = source.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n}(?=\\r?\\n|$)`));
  assert.ok(match, `${name} implements the dashboard display filters`);
  vm.runInContext(match[0],context);
}
const plain = value => JSON.parse(JSON.stringify(value));
assert.deepEqual(plain(context.getDashboardLatencyInfo({history:[]})), {latency:0,latencyState:'unknown'});
assert.equal(context.getDashboardLatencyInfo({history:[{delay:0}]}).latencyState,'unavailable');
assert.equal(context.getDashboardLatencyInfo({history:[{delay:1200}]}).latencyState,'available');
assert.equal(context.getDashboardLatencyInfo({alive:false,history:[{delay:100}]}).latencyState,'unavailable');
assert.equal(context.getDashboardLatencyInfo({history:[{delay:'bad'}]}).latencyState,'unknown');
const filters={hideUnavailable:true,hideSlow:true,maxLatency:1000};
assert.equal(context.isDashboardOutboundVisible({selected:true,latency:2000},filters),true,'active outbound remains identifiable');
assert.equal(context.isDashboardOutboundVisible({isGroup:true,latency:2000},filters),true,'group control stays visible');
assert.equal(context.isDashboardOutboundVisible({latency:0,latencyState:'unknown'},filters),true,'untested is not unavailable');
assert.equal(context.isDashboardOutboundVisible({latency:0,latencyState:'unavailable'},filters),false);
assert.equal(context.isDashboardOutboundVisible({latency:1000,latencyState:'available'},filters),true,'threshold is inclusive');
assert.equal(context.isDashboardOutboundVisible({latency:1001,latencyState:'available'},filters),false);
assert.equal(context.isDashboardOutboundVisible({reason:'Не поддерживается'},filters),false);
assert.equal(context.isDashboardOutboundVisible({latency:1500}, {...filters,hideSlow:false}),true);
assert.equal(context.isDashboardOutboundVisible({latencyState:'unavailable'}, {...filters,hideUnavailable:false}),true);
assert.equal(context.isDashboardOutboundVisible({latency:1200}, {...filters,maxLatency:NaN}),false,'invalid threshold uses safe default');
const nodes = node => typeof node==='object' && node ? [node,...[node.children].flat(Infinity).flatMap(nodes)] : [];
let changes=[];
const panel=context.renderDashboardFilters(filters,(patch)=>changes.push(patch));
const controls=nodes(panel).filter(node=>node.tag==='input');
assert.equal(controls.length,3);
assert.deepEqual(controls.map(node=>node.attrs.type),['checkbox','checkbox','number']);
controls[0].attrs.change({target:{checked:false}});
assert.equal(changes[0].hideUnavailable,false);
controls[2].attrs.change({target:{value:'2000',setCustomValidity(){}}});
assert.equal(changes[1].maxLatency,2000);
controls[2].attrs.change({target:{value:'',setCustomValidity(){}}});
assert.equal(changes.length,2,'invalid input must not change the filter');
assert.ok(JSON.stringify(panel).includes('Скрыть недоступные'));
assert.ok(JSON.stringify(panel).includes('Скрыть медленные'));
const section={displayName:'main',canTestLatency:false,withTagSelect:true,outbounds:[
  {displayName:'fast',latency:80,latencyState:'available'},
  {displayName:'slow',latency:2000,latencyState:'available'},
  {displayName:'unknown',latency:0,latencyState:'unknown'},
]};
const rendered=context.renderDefaultState({section,displayFilters:filters});
assert.ok(nodes(rendered).filter(node=>Array.isArray(node.children)).every(node=>!node.children.includes(null)),
  'native LuCI must not render a literal null in dashboard sections');
const labels=nodes(rendered).filter(node=>node.tag==='b').map(node=>node.children);
assert.deepEqual(labels,['fast','unknown']);
assert.equal(section.outbounds.length,3,'display filtering never removes or disables nodes');
const empty=context.renderDefaultState({section:{...section,outbounds:[section.outbounds[1]]},displayFilters:filters});
assert.match(JSON.stringify(empty),/Все узлы скрыты фильтрами/);
const fixed=context.renderDefaultState({section:{...section,withTagSelect:false},displayFilters:filters});
assert.equal(nodes(fixed).filter(node=>node.tag==='b').length,3,'non-selector section is never concealed');
let stored=null;
context.localStorage={getItem:()=>stored,setItem:(_key,value)=>stored=value};
context.saveDashboardDisplayFilters(filters);
assert.deepEqual(plain(context.loadDashboardDisplayFilters()), filters,'preferences survive page reload without UCI');
stored='{invalid';
assert.equal(context.loadDashboardDisplayFilters().maxLatency,1000);
context.localStorage={getItem:()=>{throw new Error('disabled')},setItem:()=>{throw new Error('disabled')}};
assert.doesNotThrow(()=>context.loadDashboardDisplayFilters());
assert.doesNotThrow(()=>context.saveDashboardDisplayFilters(filters));
assert.match(source,/diff\.dashboardDisplayFilters/,'filter changes refresh only the dashboard');
assert.match(source,/\.\.\.getDashboardLatencyInfo\(item\?\.value\)/,'URLTest history retains unavailable vs unknown');
console.log('PASS: dashboard display filters, inclusive threshold, unknown results, controls and non-mutating rendering');
