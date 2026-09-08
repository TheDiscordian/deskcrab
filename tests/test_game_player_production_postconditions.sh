#!/bin/bash
# Grounded split-packet replay: tree swings preceded acquisition, and a make
# answer's partial inventory update let a new pair consume the preceding result.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
mkdir -p "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR"
python3 - "$SANDBOX_REPO/lib" <<'PY' && ok "production split-packet and primitive ownership assertions" || fail "production split-packet and primitive ownership assertions"
import copy,sys,time
sys.path.insert(0,sys.argv[1])
import game_player as gp
now=int(time.time()*1000)
base=dict(ts=now,tick=1,logged_in=True,x=131,z=647,walking=False,
          in_combat=False,dialogue_open=False,dialogue_options=[],messages=[],
          inventory=[dict(id=13,count=1),dict(id=14,count=2)],
          skills=[dict(id=8,name='Woodcut',xp=15000),dict(id=9,name='Fletching',xp=2000)],
          objects=[dict(id=1,x=132,z=647,commands=['Chop','Examine'])])
def after(b=base,**kw):
    s=copy.deepcopy(b);s.update(ts=b["ts"]+1,tick=b["tick"]+1);s.update(kw);return s
obs=gp.make_action_observation(1,'interact-object',['obj=1','x=132','z=647','cmd=1'],base)
assert obs['baseline']['object_command']=='chop'
assert gp.observed_object_command(base,dict(obj='1',x='133',z='647',cmd='1'))==''
assert gp.observed_object_command(base,dict(obj='1',x='132',z='647',cmd='2'))=='examine'
assert gp.observed_object_command(base,dict(obj='1',x='132',z='647',cmd='9'))==''
assert gp.observed_object_command(base,{})==''
swing=[dict(id=1,channel='quest',text='You swing your steel axe at the tree...')]
success=[dict(id=2,channel='quest',text='You get some wood')]
assert gp.action_completion(obs,after(messages=swing)) is None
assert gp.action_completion(obs,after(messages=success)) is None
assert gp.action_completion(obs,after(objects=[])) is None
items=[dict(id=13,count=1),dict(id=14,count=3)]
skills=[dict(id=8,name='Woodcut',xp=15025),dict(id=9,name='Fletching',xp=2000)]
assert gp.action_completion(obs,after(inventory=items,messages=success)) is None
assert gp.action_completion(obs,after(skills=skills,messages=success)) is None
# Live 20:27:36: inventory and XP preceded scenery removal and caused two
# dispatched object-mismatch refusals against the same normal tree.
assert gp.action_completion(obs,after(inventory=items,skills=skills)) is None
assert gp.action_completion(obs,after(inventory=items,skills=skills,objects=None)) is None
assert gp.action_completion(obs,after(inventory=items,skills=skills,objects=[]))['result']=='done'
assert gp.action_completion(obs,after(inventory=items,skills=skills,objects=[dict(id=4,x=132,z=647)]))['result']=='done'
# An unrelated tree disappearing is not our target's terminal packet.
assert gp.action_completion(obs,after(inventory=items,skills=skills,objects=base['objects'])) is None
other=after(objects=[dict(id=306,x=132,z=647,commands=['Chop','Examine'])])
other_obs=gp.make_action_observation(12,'interact-object',['obj=306','x=132','z=647','cmd=1'],other)
assert gp.action_completion(other_obs,after(other,inventory=items,skills=skills))['result']=='done'
pointy=after(objects=[dict(id=0,x=132,z=647,commands=['Chop','Examine'])])
pointy_obs=gp.make_action_observation(13,'interact-object',['obj=0','x=132','z=647','cmd=1'],pointy)
assert gp.action_completion(pointy_obs,after(pointy,inventory=items,skills=skills)) is None
assert gp.action_completion(pointy_obs,after(pointy,inventory=items,skills=skills,objects=[]))['result']=='done'
assert gp.action_completion(obs,after(inventory=items,skills=[dict(id=8,name='Woodcut',xp=15000),dict(id=9,name='Fletching',xp=2010)])) is None
for text in ('You slip and fail to hit the tree','You are too tired to cut the tree','You need an axe to chop this tree down'):
    assert gp.action_completion(obs,after(messages=[dict(id=3,channel='quest',text=text)]))['result']=='failed'
# An ordinary ladder still owns its floor transition.
ladder=gp.make_action_observation(2,'interact-object',['obj=5','x=132','z=647'],base)
assert gp.action_completion(ladder,after(z=1591))['result']=='done'
menu=after(dialogue_open=True,dialogue_options=['Make arrow shafts','Make shortbow','Make longbow'])
obs=gp.make_action_observation(3,'choose-dialogue',['text=Make longbow'],menu)
closed=after(menu,dialogue_open=False,dialogue_options=[])
def cut(**kw):return after(closed,**kw)
message=[dict(id=4,channel='game',text='You carefully cut the wood into a longbow')]
assert gp.action_completion(obs,closed) is None
assert gp.action_completion(obs,cut(messages=message)) is None
assert gp.action_completion(obs,cut(inventory=[dict(id=13,count=1),dict(id=14,count=1)])) is None
assert gp.action_completion(obs,cut(inventory=base['inventory']+[dict(id=276,count=1)])) is None
assert gp.action_completion(obs,cut(skills=[dict(id=8,name='Woodcut',xp=15000),dict(id=9,name='Fletching',xp=2010)])) is None
product=[dict(id=13,count=1),dict(id=14,count=1),dict(id=276,count=1)]
assert gp.action_completion(obs,cut(inventory=product))['result']=='done'
assert gp.action_completion(obs,after(menu,inventory=product)) is None
assert gp.action_completion(obs,cut(messages=[dict(id=5,channel='game',text='You need a higher level')]))['result']=='failed'
# The next pair ignores late XP/output and waits for its own server menu.
next_obs=gp.make_action_observation(4,'use-item-item',['item=13','target=14'],cut(inventory=product))
late=cut(inventory=product,skills=[dict(id=8,name='Woodcut',xp=15000),dict(id=9,name='Fletching',xp=2010)])
late.update(tick=next_obs["baseline"]["tick"]+1,ts=next_obs["baseline"]["ts"]+1)
assert gp.action_completion(next_obs,late) is None
late.update(dialogue_open=True,dialogue_options=menu['dialogue_options'])
assert gp.action_completion(next_obs,late)['result']=='done'
# Generic NPC dialogue remains response driven.
bank=after(dialogue_open=True,dialogue_options=['Access my bank','No thanks'])
bank_obs=gp.make_action_observation(5,'choose-dialogue',['text=Access my bank'],bank)
assert gp.action_completion(bank_obs,after(bank,bank_open=True))['result']=='done'
# Primitive clicks cannot bypass the enforced pair's semantic ownership.
r=dict(name='held-pair',enabled=True,trigger=dict(activity_is='fletching'),action=dict(type='use-item-item',item=13,target=14))
cfg=dict(rules=[r])
for item in (13,14):
    for button in (1,2,3):
        assert gp.rules_own_direct_action(cfg,'click-inventory',dict(item=item,button=button),'goal','fletching')[0]==['held-pair']
assert not gp.rules_own_direct_action(cfg,'click-inventory',dict(item=350),'goal','fletching')[0]
assert not gp.rules_own_direct_action(cfg,'click-inventory',dict(item=13),'goal','banking')[0]
r['enabled']=False
assert not gp.rules_own_direct_action(cfg,'click-inventory',dict(item=13),'goal','fletching')[0]
print('Production and ownership checks passed')
PY
