"""Run through test_game_loadout.sh: no live game or model calls."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import sys
import unittest
from unittest.mock import patch

if 'SANDBOX' not in os.environ:
    raise SystemExit('run tests/test_game_loadout.sh')
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import game_player as gp
import game_loadout as gl
import game_decisions as gd


class Preparation(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir=os.environ['SANDBOX'])
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.data, self.state = self.root/'data', self.root/'state'
        self.data.mkdir(); self.state.mkdir()
        env = patch.dict(os.environ, DESKCRAB_GAME_DIR=str(self.data),
                         DESKCRAB_GAME_STATE_DIR=str(self.state),
                         BETTY_OPENRSC_MEMORY=str(self.root/'absent'))
        env.start(); self.addCleanup(env.stop)
        for k, v in {'objective':'skill target', 'activity':'fletching', 'plan':'Cut and sell locally',
                     'food-heals.xml':'<map/>', 'session.json':json.dumps({'started':gp.now_ms(),'limit_ms':7200000,'grace_ms':600000,'ended':None}),
                     'loadout-policy.json':'{"enabled":true}'}.items():
            (self.data/k).write_text(v)
        self.doc = {'risk':'No hostile creatures on the observed local production route',
                    'min_working_slots':28, 'items':[
                        {'id':13,'role':'tool','min':1,'max':1,'reason':'Cut logs'},
                        {'id':14,'role':'material','min':0,'max':29,'reason':'Batch input'},
                        {'id':276,'role':'product','min':0,'max':29,'reason':'Batch output'}]}
        self.decision = {'key':'output','choice':'Sell the output at a nearby general store',
                         'reason':'Dispose of unneeded output and free useful batch capacity',
                         'trigger':'Completed batch or full bag','items':[276],'disposition':'sell'}
        self.snap = {'v':1,'ts':gp.now_ms(),'tick':42,'logged_in':True,'walking':False,
                     'in_combat':False,'x':100,'z':100,'hits':31,'hits_max':31,'fatigue':0,
                     'sleeping':False,'talking_to_npc':False,'inventory':[{'id':13,'count':1}],
                     'messages':[],'players':[],'npcs':[],'objects':[],'bounds':[],
                     'ground_items':[],'skills':[]}
        self.put_snapshot()
        self.cfg = {'v':1,'defaults':{'stale_ms':60000,'min_action_interval_ms':0,
                    'max_actions_per_min':0,'inflight_timeout_ms':100},'rules':[],'unfinished':[]}
        (self.data/'learned-rules.json').write_text(json.dumps(self.cfg))
        gd.save(self.decision)
        self.declare()

    def put_snapshot(self):
        self.snap['ts'] = gp.now_ms()
        (self.state/'state.json').write_text(json.dumps(self.snap))

    def declare(self):
        (self.data/'loadout.json').write_text(json.dumps({'context':gl.context(),'declaration':self.doc}))

    def assess(self):
        return gl.assessment(self.snap)

    def test_candidate_replay_can_ground_a_disabled_pickup_before_arming(self):
        rule = {'name':'new-corpse','enabled':False,'priority':900,
                'cooldown_ms':0,'hold_ticks':1,
                'trigger':{'activity_is':'prayer-training','ground_item_visible':18},
                'action':{'type':'take-ground','item':18}}
        self.cfg['rules'] = [rule]
        snap = dict(self.snap,ground_items=[{'id':18,'x':100,'z':100,'reachable':True}])
        case = {'name':'new-corpse','expect':'new-corpse','candidate':True,
                'snapshot':snap,'activity':'prayer-training','objective':'skill target',
                'expect_action':{'item':18}}
        with patch.object(gp,'load_tests',return_value={'cases':[case]}):
            self.assertEqual(gp.run_suite(self.cfg),([],1))
            self.assertFalse(rule['enabled'])
            self.assertIsNone(gp.predict(self.cfg,snap,'skill target','prayer-training')[0])
            self.cfg['rules'] = []
            self.assertTrue(gp.run_suite(self.cfg)[0])
        self.cfg['rules'] = [rule]
        (self.data/'learned-rules.json').write_text(json.dumps(self.cfg))
        f=self.root/'candidate.json'; f.write_text(json.dumps(snap))
        args=SimpleNamespace(action='add',name='new-corpse',snapshot=str(f),
                expect='new-corpse',expect_action='{"item":18}',candidate=True,
                objective='skill target',activity='prayer-training')
        with contextlib.redirect_stdout(io.StringIO()): gp.cmd_test(args)
        self.assertTrue(gp.load_tests()['cases'][0]['candidate'])
        self.assertFalse(gp.load_config()['rules'][0]['enabled'])

    def test_prayer_attack_operation_is_not_mislabeled_burial(self):
        # Observed kill/loot/bury mode was ordered to bank its equipped armour
        # and switch to a different mode solely because its name said Prayer.
        (self.data/'activity').write_text('prayer-training')
        self.snap['inventory'] = [{'id':i,'equipped':True} for i in (72,114,9,209)]
        attack = {'name':'bone-source','enabled':True,'priority':700,
                  'cooldown_ms':0,'hold_ticks':1,
                  'trigger':{'activity_is':'prayer-training'},
                  'action':{'type':'attack-npc','npc':72}}
        self.cfg['rules'] = [attack]
        (self.data/'learned-rules.json').write_text(json.dumps(self.cfg))
        self.assertIsNone(gp.xp_activity_mismatch('Strength:+100_total;Prayer:+8_total','prayer-training'))
        self.assertNotIn('hauling',gp.reflection_fields(self.snap))
        self.assertEqual(gp.xp_activity_mismatch('Cooking:+100_total','prayer-training'),'Cooking')
        for replacement in (
                dict(attack,enabled=False),
                dict(attack,trigger={'activity_is':'prayer-training','objective_is':'other'}),
                dict(attack,trigger={})):
            self.cfg['rules'] = [replacement]
            (self.data/'learned-rules.json').write_text(json.dumps(self.cfg))
            self.assertEqual(gp.xp_activity_mismatch('Strength:+100_total','prayer-training'),'Strength')
            self.assertIn('hauling',gp.reflection_fields(self.snap))
        self.cfg['rules'] = [attack]
        (self.data/'learned-rules.json').write_text(json.dumps(self.cfg))
        (self.data/'activity').write_text('burying')
        self.assertIn('hauling',gp.reflection_fields(self.snap))

    def test_incidental_arrow_cannot_recreate_banking_detour(self):
        # Live 2026-09-08: after banking the unwanted arrow, a global pickup
        # diverted a fletching route 18 tiles and immediately invalidated loadout.
        self.snap['ground_items'] = [{'id':11,'x':101,'z':100,'reachable':True}]
        rule = {'name':'old-arrow-loot','action':{'type':'take-ground','item':11}}
        self.assertIsNotNone(gp.compile_player_action(rule,self.snap,{},'min')[0])
        action, why = gp.compile_live_player_action(rule,self.snap,{},'min')
        self.assertIsNone(action); self.assertIn('inventory-pickup-undeclared-item:11',why)
        self.put_snapshot()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(gp.emit_player_action('action.json',
                {'type':'take-ground','item':11,'x':101,'z':100},3,gp.now_ms()))
        self.assertFalse((self.state/'action.json').exists())

    def test_pickup_limits_and_preparation_exceptions(self):
        take = lambda iid: gl.check_pickup({'type':'take-ground','item':iid}, self.snap)
        take(14)
        with self.assertRaisesRegex(ValueError,'at-maximum:13'): take(13)
        self.snap['inventory'] += [{'id':14,'count':29}]
        with self.assertRaisesRegex(ValueError,'at-maximum:14'): take(14)
        for activity in ('travelling','travel','transit','walking','journey','trading','selling','shopping'):
            (self.data/'activity').write_text(activity)
            self.assertEqual(self.assess()['state'], 'preparation-mode')
            with self.assertRaisesRegex(ValueError,'undeclared-item:11'): take(11)
        for activity in ('resupply','banking','recovery'):
            (self.data/'activity').write_text(activity);take(11)
        (self.data/'activity').write_text('fletching')
        (self.data/'plan').write_text('Changed method')
        with self.assertRaisesRegex(ValueError,'needs-review'): take(11)
        (self.data/'activity').write_text('travelling');take(11)
        (self.data/'activity').write_text('fletching')
        (self.data/'loadout-policy.json').write_text('{"enabled":false}')
        take(11)
        (self.data/'loadout-policy.json').write_text('{"enabled":true}')
        for kind in ('click-inventory','sidestep','retreat','use-item-ground'):
            gl.check_pickup({'type':kind,'item':11},self.snap)

    def test_full_productive_batch_is_ready(self):
        self.snap['inventory'] += [{'id':276,'count':1} for _ in range(29)]
        result = self.assess()
        self.assertEqual(result['state'], 'ready')
        self.assertEqual(result['occupied_slots'],30)
        self.assertEqual(result['working_capacity'],29)

    def test_old_food_reserve_requires_actual_removal(self):
        self.snap['inventory'] += [{'id':350,'name':'Cooked food','count':1} for _ in range(8)]
        self.assertEqual(self.assess()['state'],'needs-preparation')
        self.declare()  # recording a plan again cannot remove real inventory
        self.assertEqual(self.assess()['working_capacity'],21)
        self.snap['inventory'] = self.snap['inventory'][:1]
        self.assertEqual(self.assess()['state'],'ready')

    def test_missing_tool_and_excess_stack_are_detected(self):
        self.snap['inventory'] = [{'id':14,'count':30}]
        issues = ';'.join(self.assess()['issues'])
        self.assertIn('missing 13',issues)
        self.assertIn('maximum 29',issues)

    def test_context_changes_require_review_but_preparation_detour_is_usable(self):
        for name, value in [('objective','new goal'),('plan','new method'),
                            ('activity','mining'),('session.json','{"started":2}')]:
            with self.subTest(name=name):
                old=(self.data/name).read_text(); (self.data/name).write_text(value)
                self.assertEqual(self.assess()['state'],'needs-review')
                (self.data/name).write_text(old)
        (self.data/'activity').write_text('banking')
        self.assertEqual(self.assess()['state'],'preparation-mode')
        (self.data/'activity').write_text('fletching')
        self.assertEqual(self.assess()['state'],'ready')

    def test_preparation_named_mode_reports_route_gate_and_real_recovery(self):
        # Startup evidence: a preparation-sounding mode held the resident route
        # while manual coordinate probes wasted minutes without any inventory change.
        (self.data/'activity').write_text('combat-prep')
        result = self.assess()
        self.assertEqual(result['state'], 'needs-review')
        self.assertIn('not a path failure', result['recovery'])
        self.assertIn('play activity --consider', result['recovery'])
        self.assertIn('banking, travel, or resupply', result['recovery'])
        (self.data/'activity').write_text('banking')
        self.assertEqual(self.assess()['state'], 'preparation-mode')

    def test_familiar_detour_compares_complete_route_before_reuse(self):
        # Observed route: a nine-link familiar chain from (94,647) to a bank
        # was longer than the live cache's 44 walking steps through a gate.
        points = [[90,649], [85,657], [85,665], [82,673], [81,681],
                  [86,689], [86,693], [86,692], [91,695]]
        path = [[x,z,str(i)] for i,(x,z) in enumerate(points)]
        route = {'x':93,'z':693,'arrive':3,'objective':'skill target',
                 'landmark':{'name':'Banker'},'status':'active'}
        snap = dict(self.snap, x=94, z=647)
        plan = {'status':'ok','steps':44,'waypoints':[[92,650],[91,650],[94,690]],
                'portals':[{'kind':'object','id':180,'x':92,'z':649,'dir':0,
                            'from':[92,650],'to':[91,650]}]}
        with patch.object(gp,'verified_navigation_path',return_value=path), \
                patch.object(gp,'client_cache_route_plan',return_value=plan) as query:
            result, leg = gp.prepare_navigation_route(route,snap)
        self.assertEqual(query.call_count,1)
        self.assertEqual(result['planner'],'client-cache')
        self.assertEqual(leg,(92,650))
        self.assertEqual((result['x'],result['z']),(93,693))
        self.assertEqual(result['next_portal']['id'],180)

    def test_direct_links_keep_fast_path_and_real_terrain_detours_stay_valid(self):
        route = {'x':116,'z':100,'arrive':0,'objective':'skill target','status':'active'}
        path = [[108,100,'one'],[116,100,'two']]
        with patch.object(gp,'verified_navigation_path',return_value=path), \
                patch.object(gp,'client_cache_route_plan') as query:
            result, leg = gp.prepare_navigation_route(route,self.snap)
        query.assert_not_called()
        self.assertEqual(result['planner'],'verified-links')
        path = [[100,108,'one'],[108,108,'two'],[116,100,'three']]
        with patch.object(gp,'verified_navigation_path',return_value=path), \
                patch.object(gp,'client_cache_route_plan',return_value={'status':'ok','steps':30}):
            result, leg = gp.prepare_navigation_route(route,self.snap)
        self.assertEqual(result['planner'],'verified-links')

    def test_detour_comparison_failure_cannot_silently_resume_familiar_route(self):
        route = {'x':116,'z':100,'arrive':0,'objective':'skill target','status':'active'}
        path = [[100,108,'one'],[108,108,'two'],[116,100,'three']]
        for plan in ({'status':'error','reason':'client-cache-planner-timeout'},
                     {'status':'ok','steps':None}, {'status':'ok','steps':True}):
            with patch.object(gp,'verified_navigation_path',return_value=path), \
                    patch.object(gp,'client_cache_route_plan',return_value=plan):
                result, leg = gp.prepare_navigation_route(route,self.snap)
            self.assertEqual(result['status'],'blocked')
            self.assertIsNone(leg)
            self.assertEqual((result['x'],result['z']),(116,100))

    def test_food_is_allowed_when_justified_for_this_activity(self):
        self.doc['risk']='Observed attacks on this training route; food is consumed between fights'
        self.doc['min_working_slots']=20
        self.doc['items'].append({'id':350,'role':'food','min':2,'max':8,'reason':'Observed route damage'})
        self.declare()
        self.snap['inventory'] += [{'id':350,'count':1} for _ in range(8)]
        self.assertEqual(self.assess()['state'],'ready')

    def test_corruption_does_not_disable_gate(self):
        (self.data/'loadout-policy.json').write_text('broken')
        (self.data/'loadout.json').write_text('broken')
        self.assertEqual(self.assess()['state'],'needs-review')

    def test_product_needs_saved_disposal_choice(self):
        gd.save(close='output',reason='Previous production method finished')
        self.assertIn('durable disposal decision',';'.join(self.assess()['issues']))

    def test_decision_survives_inventory_and_session_context_changes(self):
        (self.data/'activity').write_text('banking')
        (self.data/'session.json').write_text('{"started":2}')
        with self.assertRaisesRegex(ValueError,'contradicts sell'):
            gd.check('bank-deposit',276)
        gd.check('shop-sell',276)
        gd.check('bank-deposit',350)
        gd.check('bank-withdraw',276)

    def test_changing_decision_requires_reason_and_retains_previous_value(self):
        changed = dict(self.decision,disposition='bank',choice='Bank output for new recipe')
        with self.assertRaisesRegex(ValueError,'--revise'):
            gd.save(changed)
        gd.save(changed,revise='New recipe unlock uses this output as input')
        gd.check('bank-deposit',276)
        with self.assertRaises(ValueError):gd.check('shop-sell',276)
        history=gd.read()['history'][-1]
        self.assertEqual(history['before']['decision'],self.decision)
        self.assertIn('recipe unlock',history['reason'])

    def test_conflicting_alias_decision_is_refused(self):
        with self.assertRaisesRegex(ValueError,'already belongs'):
            gd.save(dict(self.decision,key='another-output'))

    def test_live_and_direct_disposal_guards(self):
        self.snap['bank_open']=True
        self.put_snapshot()
        with self.assertRaises(SystemExit):
            gp.cmd_action_arm(SimpleNamespace(id=2,type='bank-deposit',fields=['item=276','amount=all']))
        self.assertFalse((self.state/'action-observation.json').exists())
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(gp.emit_player_action('action.json',{'type':'drop-inventory','item':276},2,gp.now_ms()))
        self.assertFalse((self.state/'action.json').exists())
        with patch.object(gp,'compile_player_action',return_value=({'type':'click-inventory','item':276},None)):
            action,why=gp.compile_live_player_action({},self.snap,{},'first')
        self.assertIsNone(action)
        self.assertIn('decision-conflict',why)

    def test_runtime_yields_for_inventory_but_messages_still_own_the_turn(self):
        self.snap['inventory'] += [{'id':350,'count':1}]
        self.put_snapshot()
        output=io.StringIO()
        with contextlib.redirect_stdout(output):
            verdict,code=gp.step_once(self.cfg,'skill target','fletching',100)
        self.assertEqual((verdict,code),('no-rule-matched',gp.EXIT_NO_RULE))
        self.assertIn('inventory_prepare',output.getvalue())
        # The foreground `play` path reads reflection fields from the resident heartbeat.
        self.assertIn('needs-preparation', gp.reflection_fields(self.snap)['inventory_prepare'])
        state=gp.load_player_state()
        state['pending_messages']=[{'id':5,'channel':'local','sender':'Fixture friend',
            'text':'hello','captured_ts':gp.now_ms()-60000}]
        state['message_settle_until']=0
        gp.save_player_state(state)
        with contextlib.redirect_stdout(io.StringIO()):
            verdict,code=gp.step_once(self.cfg,'skill target','fletching',100)
        self.assertEqual(verdict,'player-message')

    def test_reply_saves_choice_before_chat_dispatch(self):
        gd.save(close='output',reason='Fixture reset')
        path=self.root/'decision.json'; path.write_text(json.dumps(self.decision))
        state=gp.load_player_state()
        state['pending_messages']=[{'id':5,'channel':'local','sender':'Fixture friend',
            'text':'please sell','captured_ts':gp.now_ms()-60000}]
        gp.save_player_state(state)
        def emitted(*args):
            self.assertEqual(gd.active(),[self.decision])
            raise RuntimeError('fixture stops before real chat')
        with patch.object(gp,'emit_player_action',side_effect=emitted):
            with self.assertRaisesRegex(RuntimeError,'fixture stops'):
                gp.cmd_reply(SimpleNamespace(message_id=5,text=['I will sell the output'],decision=str(path),revise=None))

    def test_set_rejects_stale_inventory_evidence(self):
        path=self.root/'loadout.json'; path.write_text(json.dumps(self.doc))
        self.snap['ts']=0; (self.state/'state.json').write_text(json.dumps(self.snap))
        with self.assertRaisesRegex(SystemExit,'fresh'):
            gl.command(SimpleNamespace(action='set',file=str(path)))


if __name__ == '__main__':
    unittest.main()
