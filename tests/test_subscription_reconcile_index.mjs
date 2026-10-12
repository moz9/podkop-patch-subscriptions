import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'..');
const work=fs.mkdtempSync(path.join(os.tmpdir(),'podkop-reconcile-index-'));
const reference="subscription_reconcile_choices() {\n    jq --slurpfile old \"$1\" '\n        . as $new\n        | def same_source($a;$b): any(($a.sourceIds // [])[]; . as $s | ($b.sourceIds // [] | index($s)) != null);\n          def same_key($a;$b): ($a.connectionKey // \"\") != \"\" and $a.connectionKey == $b.connectionKey;\n          def same_name($a;$b): ($a.name // \"\") != \"\" and $a.name==$b.name and $a.protocol==$b.protocol and ($a.transport // \"\")==($b.transport // \"\");\n          map(. as $item\n            | [$old[0][] | select(.id==$item.id)] as $exact\n            | [$old[0][] | select(same_source(.;$item) and same_key(.;$item))] as $key\n            | [$old[0][] | select(same_source(.;$item) and same_name(.;$item))] as $name\n            | (if ($exact|length)==1 then $exact[0]\n               elif ($key|length)==1 and ([$new[]|select(same_source(.;$item) and same_key(.;$item))]|length)==1 then $key[0]\n               elif ($name|length)==1 and ([$new[]|select(same_source(.;$item) and same_name(.;$item))]|length)==1 then $name[0]\n               else null end) as $previous\n            | .selectionId=($previous.selectionId // $previous.id // .id)\n            | .selectionNew=($previous==null and ($old[0]|length)>0))\n    ' \"$2\"\n}";
const invoke=(source,old,next)=>{
 fs.writeFileSync(path.join(work,'old'),JSON.stringify(old));
 fs.writeFileSync(path.join(work,'new'),JSON.stringify(next));
 const r=spawnSync('sh',['-c','. "$1"; subscription_reconcile_choices "$2" "$3"','test',source,path.join(work,'old'),path.join(work,'new')],{encoding:'utf8',timeout:20000,maxBuffer:20*1024*1024});
 assert.equal(r.status,0,r.stderr || String(r.error)); return JSON.parse(r.stdout);
};
try {
 fs.writeFileSync(path.join(work,'reference'),reference);
 const module=path.join(root,'openwrt/podkop-subscription-sources.sh');
 const old=Array.from({length:80},(_,i)=>({id:String(i),name:i%9 ? 'Node '+(i%19):'',protocol:i%2?'vless':'ss',transport:i%3?'tcp':null,connectionKey:i%7?'key'+(i%23):'',sourceIds:i%5?['s'+i%3]:[],selectionId:'saved'+i}));
 const next=old.map((x,i)=>({...x,id:i%4?'new'+i:x.id,sourceIds:i%6?x.sourceIds:['other']}));
 next.push({...next[5],id:'duplicate'}, {...next[9],id:'duplicate-name'});
 assert.deepEqual(invoke(module,old,next),invoke(path.join(work,'reference'),old,next),'ambiguous buckets preserve reference results');
 for(const fixture of [[[],next],[old,[]],[[old[0],old[0]],next]]) assert.deepEqual(invoke(module,...fixture),invoke(path.join(work,'reference'),...fixture));
 // Duplicate connection/name buckets, overlapping sources and exact-ID
 // ambiguity must never transfer one node's manual choice to another.
 const duplicate=[{id:'old1',name:'same',protocol:'vless',connectionKey:'shared',sourceIds:['a','b'],selectionId:'saved1'},
   {id:'old2',name:'same',protocol:'vless',connectionKey:'shared',sourceIds:['b'],selectionId:'saved2'},
   {id:'old3',name:'same',protocol:'vless',connectionKey:'shared',sourceIds:['c'],selectionId:'saved3'}];
 const duplicateNext=[{...duplicate[2],id:'new3'},{...duplicate[1],id:'new2'},{...duplicate[0],id:'new1'}, {...duplicate[0],id:'new4'}];
 assert.deepEqual(invoke(module,duplicate,duplicateNext),invoke(path.join(work,'reference'),duplicate,duplicateNext));
 const large=Array.from({length:2000},(_,i)=>({id:String(i),name:'Node '+i,protocol:'vless',connectionKey:'key'+i,sourceIds:['source'],selectionId:'saved'+i}));
 const renamed=large.map((x,i)=>({...x,id:'new'+i,name:'Renamed '+i}));
 const result=invoke(module,large,renamed);
 assert.equal(result.length,2000);
 result.forEach((row,i)=>assert.equal(row.selectionId,'saved'+i));
 const fn=fs.readFileSync(module,'utf8').match(/subscription_reconcile_choices\(\) \{\n[\s\S]*?\n}/)[0];
 for(const dir of fs.readdirSync(path.join(root,'openwrt')).filter(x=>x.startsWith('runtime-'))) {
  const runtime=path.join(root,'openwrt',dir,'usr/bin/podkop');
  assert.equal(fs.readFileSync(runtime,'utf8').match(/subscription_reconcile_choices\(\) \{\n[\s\S]*?\n}/)[0],fn,dir+' reconciliation parity');
 }
 console.log('PASS: indexed choice identity matches reference, handles ambiguity/empty inputs and 2,000 renamed nodes');
} finally {fs.rmSync(work,{recursive:true,force:true});}
