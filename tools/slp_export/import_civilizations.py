#!/usr/bin/env python3
"""Import the local AoE2 HD land tech tree and art for Chinese and Teutons.

Uses openage's read-only DAT parser and this project's lossless SLP decoder.
No original installation files or pre-existing game assets are changed.
"""
from __future__ import annotations
import argparse
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re
import sys
import zlib

ROOT = Path(__file__).resolve().parents[2]
CIVS = {'chinese': 6, 'teutons': 4}
AGE_KEYS = ['dark', 'feudal', 'castle', 'imperial']
RESOURCES = {'FOOD_STORAGE': 'food', 'WOOD_STORAGE': 'wood', 'GOLD_STORAGE': 'gold', 'STONE_STORAGE': 'stone'}
KEY_OVERRIDES = {83:'villager', 73:'chu_ko_nu', 559:'elite_chu_ko_nu', 331:'trebuchet', 109:'town_center', 621:'town_center', 487:'gate', 77:'long_swordsman'}


def read_dat(path, openage):
    sys.path.insert(0, str(openage))
    from openage.convert.value_object.read.genie_structure import GenieStructure
    from openage.convert.value_object.read.member_access import SKIP, READ
    from openage.convert.value_object.read.media.datfile.empiresdat import EmpiresDatWrapper
    from openage.convert.value_object.init.game_version import GameEdition, GameVersion
    # Names/icons are known fields normally skipped by the openage converter.
    primitive = GenieStructure._read_primitive
    def keep_labels(self, raw, offset, export, name, storage, typ):
        if export == SKIP and name in {'name', 'icon_id'}:
            export = READ
        return primitive(self, raw, offset, export, name, storage, typ)
    GenieStructure._read_primitive = keep_labels
    try:
        raw = zlib.decompress(path.read_bytes(), -15)
        version = GameVersion(GameEdition('HD', 'HDEDITION', 'yes', [], [], {}, {}, []))
        wrapper = EmpiresDatWrapper()
        offset, _ = wrapper.read(raw, 0, version)
        if offset != len(raw):
            raise ValueError(f'DAT parser stopped at {offset}, expected {len(raw)}')
        return wrapper.empiresdat[0], len(raw)
    finally:
        GenieStructure._read_primitive = primitive


def read_strings(resources, language):
    path = resources / language / 'strings/key-value/key-value-strings-utf8.txt'
    return {int(m[1]): m[2] for m in re.finditer(r'^(\d+) "(.*)"$', path.read_text(encoding='utf-8-sig'), re.M)}


def key_for(uid, units, english):
    return KEY_OVERRIDES.get(uid) or re.sub(r'[^a-z0-9]+', '_', english.get(units[uid].language_dll_name, units[uid].name).lower()).strip('_')


def costs(rows):
    return {RESOURCES[x.type_id]: x.amount for x in rows if x.enabled and x.type_id in RESOURCES and x.amount > 0}


def as_num(value):
    return round(float(value), 5)


def hits(rows):
    return {x.type_id: x.amount for x in rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources', type=Path)
    parser.add_argument('--openage', type=Path, required=True, help='openage source root containing openage/')
    parser.add_argument('--catalog', type=Path, default=ROOT/'data/civilization_catalog.json')
    parser.add_argument('--out', type=Path, default=ROOT/'assets/sprites/civilizations')
    parser.add_argument('--catalog-only', action='store_true')
    args = parser.parse_args()
    if args.catalog_only and args.catalog.resolve() == (ROOT/'data/civilization_catalog.json').resolve():
        parser.error('--catalog-only requires a separate --catalog output; the playable catalog must retain its sprite references')
    from export_sprites import load_config
    resources = args.resources or Path(load_config(None)['aoe2_resources'])
    dat_path = resources/'_common/dat/empires2_x1_p1.dat'
    dat, length = read_dat(dat_path, args.openage)
    print(f'Parsed DAT {dat.versionstr}: {length:,} / {length:,} bytes', flush=True)
    english, chinese = read_strings(resources, 'en'), read_strings(resources, 'zh')
    civ_units = {name: {u.id0: u for rows in dat.civs[cid].units.values() for u in rows} for name,cid in CIVS.items()}
    units = civ_units['chinese']
    unit_connections = {c.id:c for c in dat.unit_connections if c.upper_building != 45}
    building_connections = {c.id:c for c in dat.building_connections if c.id not in (45,199,621)}
    # Unit 621 is the buildable full TC preview; 109 is the TC gameplay record.
    disabled = {name: {int(e.attr_d) for e in dat.effect_bundles[dat.civs[cid].tech_tree_id].effects if e.type_id == 'TECH_TOGGLE' and e.attr_d >= 0} for name,cid in CIVS.items()}
    def tech_allowed(tid, civ, visiting=frozenset()):
        if tid < 0: return True
        if tid in disabled[civ] or tid in visiting: return False
        t = dat.researches[tid]
        if t.civilization_id not in (-1, CIVS[civ]): return False
        needed = [x for x in t.required_techs if x >= 0]
        # Building-created shadow technologies have no tech prerequisites; their
        # required count is satisfied by construction, not another research.
        if not needed and t.research_location_id == -1: return True
        return sum(tech_allowed(x, civ, visiting|{tid}) for x in needed) >= t.required_tech_count
    enable_techs = {}
    for tid,t in enumerate(dat.researches):
        if t.tech_effect_id < 0: continue
        for e in dat.effect_bundles[t.tech_effect_id].effects:
            if e.type_id == 'UNIT_ENABLED' and e.attr_b == 1:
                enable_techs.setdefault(e.attr_a,[]).append(tid)
    def connection_allowed(conn, civ):
        if not tech_allowed(conn.enabling_research, civ): return False
        # Some display-tree enablement nodes are obsolete/no-op. Check actual
        # UNIT_ENABLED effects too (notably Chinese Bombard Cannon tech 188).
        actual = enable_techs.get(conn.id, [])
        if actual and not any(tech_allowed(tid,civ) for tid in actual): return False
        if not tech_allowed(getattr(conn,'required_research',-1), civ): return False
        for cid,other in zip(conn.other_connected_ids[:conn.connected_slots_used], conn.other_connections):
            if other.other_connection == 'RESEARCH' and not tech_allowed(cid,civ): return False
            if other.other_connection == 'UNIT' and cid in unit_connections and not connection_allowed(unit_connections[cid],civ): return False
        return True
    def age_of(conn):
        return next((max(0,cid-1) for cid,o in zip(conn.other_connected_ids[:conn.connected_slots_used],conn.other_connections) if o.other_connection=='AGE'), 0)
    selected_units = {uid:[name for name in CIVS if connection_allowed(c,name)] for uid,c in unit_connections.items()}
    selected_units = {uid:civs for uid,civs in selected_units.items() if civs}
    selected_buildings = {uid:[name for name in CIVS if connection_allowed(c,name)] for uid,c in building_connections.items()}
    selected_buildings = {uid:civs for uid,civs in selected_buildings.items() if civs}
    keys = {uid:key_for(uid,units,english) for uid in selected_units|selected_buildings}
    selected_ids = set(keys)
    def tech_key(tid):
        return re.sub(r'[^a-z0-9]+','_', english.get(dat.researches[tid].language_dll_name, dat.researches[tid].name).lower()).strip('_') or f'tech_{tid}'
    def record(uid, civs, conn):
        u = units[uid]
        attack = hits(u.attacks); armor = hits(u.armors)
        return dict(source_id=uid,display_name=chinese.get(u.language_dll_name,english.get(u.language_dll_name,u.name)),display_name_en=english.get(u.language_dll_name,u.name),required_age=age_of(conn),civilizations=civs,cost=costs(u.resource_cost),hp=u.hit_points,attack=max(attack.get('UNITS_MELEE',0),attack.get('UNITS_PIERCE',0)),attack_range=as_num(u.weapon_range_max),min_range=as_num(u.weapon_range_min),cooldown=as_num(u.attack_speed),melee_armor=armor.get('UNITS_MELEE',0),pierce_armor=armor.get('UNITS_PIERCE',0),sight=as_num(u.line_of_sight),icon_id=u.icon_id,attack_type='pierce' if 'UNITS_PIERCE' in attack else 'melee',source_attacks=attack,source_armors=armor,source_class=u.unit_class,sprites={})
    catalog = dict(schema_version=1,source={'edition':'Age of Empires II HD / The Conquerors base data','dat':'resources/_common/dat/empires2_x1_p1.dat','dat_version':dat.versionstr,'sha256':hashlib.sha256(dat_path.read_bytes()).hexdigest(),'decompressed_bytes':length,'scope':'Chinese and Teutons standard land units and buildings; no navy, heroes or scenario objects','attributes':'DAT base attributes before technologies and civilization bonuses'},ages={},civilizations={},units={},buildings={},techs={})
    for age,tid in enumerate([104,101,102,103]):
        t=dat.researches[tid]
        catalog['ages'][AGE_KEYS[age]]=dict(source_id=tid,level=age,display_name=chinese.get(t.language_dll_name,AGE_KEYS[age]),cost=costs(t.research_resource_costs),time=t.research_time,icon_id=t.icon_id)
    for name,cid in CIVS.items():
        catalog['civilizations'][name]=dict(source_id=cid,display_name='中国' if name=='chinese' else '条顿',icon_set=dat.civs[cid].icon_set,disabled_tech_ids=sorted(disabled[name]))
    for uid,civs in selected_units.items():
        u=units[uid]; conn=unit_connections[uid]; r=record(uid,civs,conn)
        r.update(train_at=keys[conn.upper_building],speed=as_num(u.speed),train_time=u.creation_time,population=max(1,next((x.amount for x in u.resource_cost if x.type_id=='POPULATION_HEADROOM'),1)),required_techs=[tech_key(conn.required_research)] if conn.required_research>=0 else [],upgrade_from='')
        for cid,other in zip(conn.other_connected_ids[:conn.connected_slots_used],conn.other_connections):
            if other.other_connection=='UNIT' and cid in keys:r['upgrade_from']=keys[cid]
            if other.other_connection=='RESEARCH':r['required_techs'].append(tech_key(cid))
        if uid==331:
            combat=record(42,civs,conn)
            for attr in ['attack','attack_range','min_range','cooldown','attack_type','source_attacks']:
                r[attr]=combat[attr]
            r['combat_source_id']=42
            r['display_name']=chinese.get(units[42].language_dll_name,'巨型投石机')
        catalog['units'][keys[uid]]=r
    age_changes = {a:{e.attr_a:e.attr_b for e in dat.effect_bundles[tid].effects if e.type_id=='UNIT_UPGRADE'} for a,tid in enumerate([104,101,102,103])}
    for uid,civs in selected_buildings.items():
        u=units[uid];conn=building_connections[uid];r=record(uid,civs,conn)
        requirements=[keys[cid] for cid,o in zip(conn.other_connected_ids[:conn.connected_slots_used],conn.other_connections) if o.other_connection=='BUILDING' and cid in keys]
        # The tree also uses building links just for positioning upgrade lines.
        if uid not in (50,87,84,101,49):requirements=[]
        r.update(footprint=[as_num(u.radius_x*2),as_num(u.radius_y*2)],population_provided=int(next((x.amount for x in u.resource_storage if x.type==4),0)),build_time=u.creation_time,required_buildings=requirements,required_techs=[tech_key(cid) for cid,o in zip(conn.other_connected_ids[:conn.connected_slots_used],conn.other_connections) if o.other_connection=='RESEARCH'],age_variants={})
        if uid==109:r['construction_cost']=costs(units[621].resource_cost);r['construction_age']=2
        for age,key in enumerate(AGE_KEYS):
            variant=units[age_changes[age].get(uid,uid)]
            r['age_variants'][key]=dict(source_id=variant.id0,hp=variant.hit_points,melee_armor=hits(variant.armors).get('UNITS_MELEE',0),pierce_armor=hits(variant.armors).get('UNITS_PIERCE',0))
        catalog['buildings'][keys[uid]]=r
    for tid,t in enumerate(dat.researches):
        if tid in (101,102,103,104) or t.research_location_id not in keys or not t.name:continue
        civs=[civ for civ in CIVS if tech_allowed(tid,civ)]
        if not civs:continue
        effects=dat.effect_bundles[t.tech_effect_id].effects if t.tech_effect_id>=0 else []
        upgrades=[e for e in effects if e.type_id=='UNIT_UPGRADE' and e.attr_a in selected_ids and e.attr_b in selected_ids]
        if not upgrades and tid not in [47,64]:continue
        targets={e.attr_b for e in upgrades}
        required_age=max([catalog['units' if uid in selected_units else 'buildings'][keys[uid]]['required_age'] for uid in targets] or [3])
        # Choose the direct predecessor, not older ancestors repeated in DAT effects.
        pairs=[dict(**{'from':keys[e.attr_a],'to':keys[e.attr_b]}) for e in upgrades]
        chosen=next((p for p in pairs if catalog['units'].get(p['to'],{}).get('upgrade_from')==p['from']),pairs[-1] if pairs else {'from':'','to':''})
        catalog['techs'][tech_key(tid)] = dict(source_id=tid,display_name=chinese.get(t.language_dll_name,english.get(t.language_dll_name,t.name)),**chosen,upgrades=pairs,cost=costs(t.research_resource_costs),time=t.research_time,research_at=keys[t.research_location_id],required_age=required_age,civilizations=civs,icon_id=t.icon_id,required_tech_ids=[x for x in t.required_techs if x>=0])
    # Enablement 64 is the actual Bombard Tower research and has no UNIT_UPGRADE.
    for group in ['units','buildings']:
        for k,r in catalog[group].items():
            r['required_techs']=[x for x in r.get('required_techs',[]) if x in catalog['techs']]
    # Normalize runtime links after the complete filtered tree is available.
    tech_by_source = {r['source_id']:k for k,r in catalog['techs'].items()}
    for group in ['units','buildings']:
        for k,r in catalog[group].items():
            r['required_technology'] = next(iter(r.get('required_techs',[])), '')
            r['upgrades_from'] = r.get('upgrade_from','')
            r['vision'] = r['sight']
    for k,t in catalog['techs'].items():
        required = [tech_by_source[x] for x in t['required_tech_ids'] if x in tech_by_source]
        t['prerequisite_technology'] = required[-1] if required else ''
    # The tree's 109 TC is a free scenario object; 621 is the buildable definition.
    tc = civ_units['chinese'][621]
    catalog['buildings']['town_center']['cost'] = costs(tc.resource_cost)
    catalog['buildings']['town_center']['required_age'] = 2
    print('Catalog:', len(catalog['units']),'units,',len(catalog['buildings']),'buildings,',len(catalog['techs']),'technologies',flush=True)
    if not args.catalog_only:
        export_art(dat,resources,args.out,catalog,civ_units,keys,selected_units,selected_buildings,age_changes)
    # Do not replace a playable catalog with incomplete sprite references when
    # a full art export fails partway through.
    args.catalog.parent.mkdir(parents=True,exist_ok=True)
    args.catalog.write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    return 0


def export_art(dat,resources,out,catalog,civ_units,keys,selected_units,selected_buildings,age_changes):
    from original_graphics import GraphicExporter
    exporter=GraphicExporter(dat,resources,out)
    for uid,civs in selected_units.items():
        u=civ_units[civs[0]][uid];r=catalog['units'][keys[uid]]
        for action,field in [('idle','idle_graphic0'),('walk','move_graphics'),('attack','attack_sprite_id'),('die','dying_graphic')]:
            source=civ_units[civs[0]][42] if uid==331 and action in ('idle','attack') else u
            gid=getattr(source,field,-1)
            if gid>=0:r['sprites'][action]=exporter.export(gid,animation=True)
    for uid,civs in selected_buildings.items():
        r=catalog['buildings'][keys[uid]]
        for civ in civs:
            r['sprites'][civ]={}
            for age,agekey in enumerate(AGE_KEYS):
                original=621 if uid==109 else uid
                variant=age_changes[age].get(original,original)
                g=civ_units[civ][variant].idle_graphic0
                r['sprites'][civ][str(age)]=exporter.export(g,animation=False)
    catalog['icons']={'units':'res://assets/sprites/ui/icons_units','buildings':'res://assets/sprites/ui/icons_buildings'}
    catalog['icons']['technologies']=exporter.export_icons()
    stone = next(u for rows in dat.civs[0].units.values() for u in rows if u.id0 == 102)
    stone_base = exporter.export(stone.idle_graphic0, animation=False)
    catalog['resource_sprites'] = {'stone': stone_base}
    exporter.finish()


if __name__=='__main__':
    raise SystemExit(main())
