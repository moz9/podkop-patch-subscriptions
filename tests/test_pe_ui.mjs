import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const read = name => fs.readFileSync(new URL('../openwrt/' + name, import.meta.url), 'utf8').replace(/\r\n/g,'\n');
const section = read('section.js');
function options(features) {
  const records = [];
  let exported;
  const context = {form:{ListValue:1,DynamicList:2,TextValue:3,Value:4,Flag:5,DummyValue:6},
    baseclass:{extend:value=>(exported=value)},widgets:{DeviceSelect:7},uci:{get:()=>null},
    _:s=>s,main:{URLTEST_DOWNLOAD_URL_OPTIONS:{'https://example.org/file':'test'},
      DNS_SERVER_OPTIONS:{},DOMAIN_LIST_OPTIONS:{},REGIONAL_OPTIONS:[],
      validateProxyUrl:()=>({valid:true}),validateUrl:()=>({valid:true})}};
  vm.createContext(context);
  vm.runInContext('(function(){'+section+'\n})()',context);
  const makeOption=(type,key,title,description)=>{
    const record={type,key,title,description,dependencies:[],values:[],depends(...d){this.dependencies.push(d)},value(...v){this.values.push(v)}};
    records.push(record);return record;
  };
  exported.createSectionContent({
    tab(){},
    option(){return makeOption(...arguments)},
    taboption(_tab){return makeOption(...Array.from(arguments).slice(1))},
  },features);
  return records;
}
const unsupported=options([]);
assert.ok(!unsupported.some(o=>o.key==='urltest_fallback_links'));
assert.ok(!unsupported.some(o=>o.key==='urltest_download_check'));
const supported=options(['urltest.fallbacks','urltest.download_url']);
for(const key of ['urltest_fallback_links','urltest_download_check','urltest_download_url']){
  const option=supported.find(o=>o.key===key);assert.ok(option,key);
  assert.ok(option.dependencies.some(d=>d[0]==='proxy_config_type'&&d[1]==='subscription_urltest'||d[0]?.proxy_config_type==='subscription_urltest'),key+' supports subscriptions');
  assert.match(option.title,/[А-Яа-яЁё]/,key+' Russian title');
}
assert.equal(supported.find(o=>o.key==='urltest_download_check').default,'default');
assert.equal(supported.find(o=>o.key==='urltest_download_url').validate('main','https://example.org'),true);
assert.match(read('podkop.js'),/await main\.CustomPodkopMethods\.getSingBoxFeatures\(\)/);
assert.match(read('podkop.js'),/createSectionContent\(sectionsSection, singBoxFeatures\)/);
assert.match(read('podkop.js'),/Podkop PE/);
const main=read('main.js');
const c=vm.createContext({PodkopShellMethods:{getSingBoxFeatures:async()=>({success:true,data:['transport.xhttp']})}});
vm.runInContext(main.match(/async function getSingBoxFeatures\([\s\S]*?\n}/)?.[0]||'throw Error("missing getSingBoxFeatures")',c);
assert.deepEqual(Array.from(await c.getSingBoxFeatures()),['transport.xhttp']);
c.PodkopShellMethods.getSingBoxFeatures=async()=>({success:false,data:'bad'});
assert.deepEqual(Array.from(await c.getSingBoxFeatures()),[]);
console.log('PASS: PE capability-gated Russian fields support native and subscription URLTest');
