import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source=fs.readFileSync(new URL('../openwrt/settings.js',import.meta.url),'utf8');
const context=vm.createContext({main:{},_:value=>value,E:(tag,attrs,children)=>({tag,attrs,children})});
vm.runInContext('const DNS_PRIMARY_POLICY={yandex:{primaryEligible:false}};'+source.match(/const COMMUNITY_SERVICE_LABELS = \{[\s\S]*?\n};/)[0],context);
for(const name of ['dnsEndpointHost','candidateIsPrimaryEligible','resultClass','resultVerdict','compatibilityLabel','compatibilityTitle','communityServiceLabel','communityResultTitle','renderCommunityCheck','renderChecks','communityRecommendationText']) {
  const definition=source.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n}`));
  assert.ok(definition,`${name} exists`);
  vm.runInContext(definition[0],context);
}
const failedCommunity={id:'youtube',tested:true,passed:false,stable:false,passedDomains:1,totalDomains:2,failures:['youtube.example'],unstable:['video.example']};
const healthy={id:'google',dnsServer:'dns.google',provider:'Google',reliable:true,jitterMs:3,medianMs:10,p90Ms:13,compatibilityPassed:6,compatibilityTotal:6,compatibilityScore:100,communitySelected:1,communityTested:1,communityPassed:0,communityResults:[failedCommunity]};
const advisory={...healthy,communityAdvisory:true};
assert.equal(context.resultClass(advisory),'pdk-dns-optimizer__warn','advisory failures warn without rejecting healthy DNS');
assert.match(context.resultVerdict(advisory),/DNS.*стабил|Стабил.*DNS/i,'healthy DNS is not labelled unavailable');
assert.doesNotMatch(context.resultVerdict(advisory),/Недоступен|Проблема с выбранным списком/);
assert.equal(context.resultClass(healthy),'pdk-dns-optimizer__bad','old JSON retains mandatory community behavior');
assert.equal(context.resultVerdict(healthy),'Недоступен выбранный сервис');
assert.equal(context.resultVerdict({...advisory,profile:'custom'}),'Стабильно в этом тесте, только для сравнения','advisory does not hide comparison-only eligibility');
assert.equal(context.resultVerdict({...advisory,universalEligible:false}),'Стабильно, но DNS с фильтрацией','advisory does not hide filtering');
for(const failed of [{...advisory,compatibilityPassed:5},{...advisory,compatibilityScore:80},{...advisory,reliable:false,error:'nxdomain_check_failed'}])
  assert.equal(context.resultClass(failed),'pdk-dns-optimizer__bad','baseline and NXDOMAIN remain mandatory');
assert.equal(context.resultVerdict({...advisory,reliable:false,error:'nxdomain_check_failed'}),'Возможна подмена DNS-ответов');
const checks=context.renderChecks(advisory);
const community=checks.children.find(node=>node.attrs?.title?.includes('youtube.example'));
assert.ok(community,'concrete failed community domains stay visible');
assert.match(community.attrs.class,/check--warn/,'advisory failed check uses informational warning');
assert.match(community.attrs.title,/video.example/,'unstable domain diagnostics stay visible');
assert.match(community.children,/справочн/i,'community chip discloses advisory scope');
assert.match(context.communityRecommendationText(advisory),/справочн/i);
assert.match(context.communityRecommendationText(advisory),/не гарантирует/i,'DNS check is not an app guarantee');
assert.doesNotMatch(context.communityRecommendationText(healthy),/справочн/i,'old report explanatory scope remains compatible');
assert.match(source,/href:"https:\/\/github\.com\/moz9\/podkop-patch-subscriptions\/blob\/backport\/subscriptions-20261008\/docs\/user-guide\.md"/,'mandatory baseline methodology is linked from GitHub guide');
console.log('PASS: legacy optimizer advisory community UI, mandatory baseline and concrete diagnostics');
