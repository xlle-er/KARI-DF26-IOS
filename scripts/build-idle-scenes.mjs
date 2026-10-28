import fs from 'node:fs';
import { IDLE_SCENARIOS } from '../FaceSource/frontend/js/idle/idleScenarioCatalog.js';
const names = ['中性','专注','好奇','开心','困倦','害羞'];
const poses = ['neutral','attentive','curious','happy','sleepy','shy'].map((name,i)=>({id:`pose_${name}`,title:name,titleZH:names[i],body:false,pose:`pose_${name}`,steps:[]}));
const titles = {
  idle_shift_right_back_left_front: ['轻柔左前扭动', 'Soft left forward twist'],
  idle_shift_right_front_left_back: ['轻柔右前扭动', 'Soft right forward twist'],
  idle_both_front_left_soft: ['轻微左前转动', 'Tiny left forward pivot'],
  idle_custom_6: ['轻微右前转动', 'Tiny right forward pivot'],
  idle_both_front_tiny: ['轻微前进', 'Tiny forward pulse'],
  idle_custom_7: ['轻微后退', 'Tiny backward pulse'],
  idle_forward_then_backward: ['轻微前后摆动', 'Tiny forward and back'],
  idle_custom_8: ['缓慢前后摆动', 'Slow forward and back'],
  multi_forward_back: ['多次前后摆动', 'Repeated forward and back']
};
const unique = new Map();
for (const scene of IDLE_SCENARIOS) {
  if (unique.has(scene.id)) continue;
  if (!scene.steps?.some(step => step.kind === 'move') || scene.steps.some(step => !['move', 'stop', 'pause'].includes(step.kind))) continue;
  const index = unique.size + 1;
  unique.set(scene.id, {id:scene.id,title:titles[scene.id]?.[1] ?? `Body motion ${index}`,titleZH:titles[scene.id]?.[0] ?? `轻微身体动作 ${index}`,body:true,steps:scene.steps});
}
fs.mkdirSync('Native/Sources/KariNative/Resources', {recursive:true});
fs.writeFileSync('Native/Sources/KariNative/Resources/IdleScenes.json',JSON.stringify([...poses,...unique.values()],null,2)+'\n');
console.log(`Idle scene catalog: ${poses.length} expressions, ${unique.size} body scenes.`);
