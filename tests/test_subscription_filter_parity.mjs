import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const root = path.resolve(import.meta.dirname, '..');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(root,'openwrt/main.js'),'utf8').match(/function subscriptionTagMatches\([\s\S]*?\n}/)[0],context);
const work=fs.mkdtempSync(path.join(os.tmpdir(),'podkop-glob-parity-'));
const cases=[
 ['[z-a]',['z','a','m','-']], ['[a-z]',['a','m','z','-']],
 ['[!z-a]',['z','a','m']], ['[^a-c]',['a','b','c','d']],
 ['[',['[',']','x']], ['[]',['[]','x']], ['[a',['[a','a']],
 ['\\*',['*','anything']], ['(a+)+$',['aaaa','(a+)+$']],
 ['*?*',['','x','🇫🇮']], ['@prefix:FI',[' FI node','FI\u00a0node','FISH','🇫🇮 node']],
 ['@game:only',['FI node','FI Игровой']], ['@game:exclude',['FI node','FI Игровой']]
];
try {
 for(const [pattern,names] of cases) {
  fs.writeFileSync(path.join(work,'items'),JSON.stringify(names.map((name,i)=>({id:String(i),name,supported:true}))));
  const result=spawnSync('sh',['-c','. "$1"; subscription_source_policy "[]" "[]" "$2" auto "[]" "$3" "[]"','test',path.join(root,'openwrt/podkop-subscription-sources.sh'),path.join(work,'items'),JSON.stringify([pattern])],{encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
  const rows=JSON.parse(result.stdout);
  rows.forEach((row,i)=>assert.equal(context.subscriptionTagMatches(pattern,names[i]),row.runtimeEnabled,`${JSON.stringify(pattern)} against ${JSON.stringify(names[i])}: preview must match backend`));
 }
 console.log('PASS: malformed glob classes, regex-like literals, Unicode and reserved predicates match backend');
} finally {fs.rmSync(work,{recursive:true,force:true});}
