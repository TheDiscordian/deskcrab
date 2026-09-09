#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate" DESKCRAB_GAME_DIR="$SANDBOX/gdata"
mkdir -p "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR"
python3 - "$SANDBOX_REPO/lib" <<'PY' && ok 'ranged acquisition, sustained shot and release assertions' || fail 'ranged cycle assertions'
import copy,sys
sys.path.insert(0,sys.argv[1])
import game_player as gp
base=dict(ts=gp.now_ms(),tick=1,logged_in=True,x=126,z=524,walking=False,
 in_combat=False,opponent=None,inventory=[dict(id=189,count=1,equipped=True),dict(id=11,count=79)],
 skills=[dict(id=4,name='Ranged',xp=0)],npcs_truncated=False,
 npcs=[dict(sidx=580,id=11,x=123,z=524,attackable=True)],messages=[])
rule=dict(name='ranged-test',enabled=False,priority=700,cooldown_ms=0,hold_ticks=1,
 trigger=dict(activity_is='combat-training',npc_visible=11,out_of_combat=True,inventory_slots_below=30,fatigue_below=100),
 action=dict(type='attack-npc',npc=11,mode='ranged',weapon=189,ammo=11))
cfg=copy.deepcopy(gp.EMPTY_TABLE);cfg['rules']=[rule];gp.validate_config(cfg)
action,why=gp.compile_player_action(rule,base,{},None)
assert why is None and action['sidx']==580 and action['mode']=='ranged'
bad=copy.deepcopy(base);bad['inventory'][0]['equipped']=False
assert gp.compile_player_action(rule,bad,{},None)[1]=='ranged-weapon-not-equipped'
bad=copy.deepcopy(base);bad['inventory'][1]['count']=0
assert gp.compile_player_action(rule,bad,{},None)[1]=='ranged-ammunition-missing'
obs=gp.make_action_observation(1,'attack-npc',[f'{k}={v}' for k,v in action.items()],base)
def after(**kw):
 s=copy.deepcopy(base);s.update(ts=gp.now_ms()+1,tick=2);s.update(kw);return s
shot=after(opponent=dict(x=123,z=524),inventory=[dict(id=189,count=1,equipped=True),dict(id=11,count=78)])
assert gp.action_completion(obs,shot) is None # arrow + pointer is initiation, not kill
shot['skills'][0]['xp']=5
assert gp.action_completion(obs,shot) is None # per-hit XP cannot release live target
shot['npcs']=[]
assert gp.action_completion(obs,shot)['state'].endswith('ranged-target:released')
shot['npcs_truncated']=True
assert gp.action_completion(obs,shot) is None
shot.pop('npcs_truncated')
assert gp.action_completion(obs,shot) is None
assert gp.action_completion(obs,after(npcs=[])) is None # disappearing without shooting isn't success
assert gp.action_completion(obs,after(in_combat=True))['result']=='failed'
assert gp.action_completion(obs,after(inventory=[dict(id=189,count=1,equipped=False),dict(id=11,count=78)]))['result']=='failed'
assert gp.action_completion(obs,after(inventory=[dict(id=189,count=1,equipped=True)]))['result']=='failed'
# Default acquisition still accepts actual combat or ranged XP.
plain=gp.make_action_observation(2,'attack-npc',['npc=11','sidx=580'],base)
assert gp.action_completion(plain,after(in_combat=True))['result']=='done'
assert gp.action_completion(plain,after(skills=[dict(id=4,name='Ranged',xp=38)]))['result']=='done'
assert gp.xp_activity_mismatch('Ranged: +38','combat-training') is None
print('15 assertions passed')
PY
