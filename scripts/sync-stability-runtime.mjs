// Keep shipped runtimes on the same reviewed service/source blocks. Variant
// entry points outside these markers remain intact.
import fs from 'node:fs';
import path from 'node:path';
const root=path.resolve(process.argv[2]||new URL('..',import.meta.url).pathname);
for(const version of fs.readdirSync(path.join(root,'openwrt')).filter(n=>/^runtime-/.test(n))){
 const file=path.join(root,'openwrt',version,'usr/bin/podkop');
 if(!fs.existsSync(file))continue;
 let code=fs.readFileSync(file,'utf8').replaceAll('\r\n','\n');
 for(const [source,marker] of [['podkop-service-snapshot.sh','subscription_service_snapshot_v1'],['podkop-subscription-sources.sh','subscription_sources_v1']]){
   const block=fs.readFileSync(path.join(root,'openwrt',source),'utf8').replaceAll('\r\n','\n').trimEnd();
   const begin=code.indexOf(`# ${marker} begin`),end=code.indexOf(`# ${marker} end`,begin);
   if(begin<0||end<0)throw Error('missing shared block '+file+' '+marker);
   code=code.slice(0,begin)+block+code.slice(end+(`# ${marker} end`).length);
 }
 if(!code.includes('\nsubscription_config_apply)\n')){
   code=code.replace('\nget_subscription_operation_status)\n','\nsubscription_config_apply)\n    subscription_config_apply\n    ;;\nget_subscription_operation_status)\n');
 }
 fs.writeFileSync(file,code);
}
