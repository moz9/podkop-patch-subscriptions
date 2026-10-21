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
 // Older supported engines must keep the same restart admission boundary.
 if(!code.includes('# subscription_safe_restart_v1:')){
   code=code.replace('local skip_list_update_started=0 PODKOP_SERVICE_REUSE_ADMITTED_CONFIG=0',
     'local skip_list_update_started=0 PODKOP_SERVICE_REUSE_ADMITTED_CONFIG="${PODKOP_SERVICE_RESTART_CONTINUITY:-0}"');
   for(const name of ['restart','reload']){
     const begin=code.indexOf('\n'+name+'() {'),end=code.indexOf('\n}',begin);
     if(begin<0||end<0)throw Error('missing lifecycle '+file+' '+name);
     let body=code.slice(begin,end).replace('    subscription_services_preflight || return 1',
       '    local PODKOP_SERVICE_RESTART_CONTINUITY=0\n    subscription_services_restart_prepare || return 1');
     if(name==='restart')body=body.replace(name+'() {',name+'() {\n    # subscription_safe_restart_v1: validate before destructive rc.common stop.');
     code=code.slice(0,begin)+body+code.slice(end);
   }
 }
 if(!code.includes('# subscription_safe_start_v1:')){
   const begin=code.indexOf('start_main() {'),gate=code.indexOf('    if ! subscription_services_preflight; then',begin);
   if(gate<0)throw Error('missing start admission '+file);
   code=code.slice(0,gate)+`    # subscription_safe_start_v1: fresh re-tests never authorize new boot pools.
    if [ "\${PODKOP_SUBSCRIPTION_APPLY_NOW:-0}" != 1 ] &&
       { [ -e "$(subscription_services_snapshot_dir)/snapshot.json" ] || [ -L "$(subscription_services_snapshot_dir)/snapshot.json" ]; }; then
        subscription_services_snapshot_continuity_prepare || return 1
        PODKOP_SERVICE_REUSE_ADMITTED_CONFIG=1
    fi

    if [ "$PODKOP_SERVICE_REUSE_ADMITTED_CONFIG" = 1 ]; then
        subscription_services_snapshot_continuity_prepare || return 1
    elif ! subscription_services_preflight; then`+code.slice(gate+'    if ! subscription_services_preflight; then'.length);
 }
 const start=code.indexOf('start_main() {'),check=code.indexOf('    check_requirements',start);
 if(!code.slice(start,check).includes('subscription_services_continuity_context_ready')){
   code=code.slice(0,check)+'    [ "$PODKOP_SERVICE_REUSE_ADMITTED_CONFIG" != 1 ] || subscription_services_continuity_context_ready || return 1\n\n'+code.slice(check);
 }
 fs.writeFileSync(file,code);
}
