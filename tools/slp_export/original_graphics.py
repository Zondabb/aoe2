"""DAT graphic references to lossless atlases, preserving composite offsets."""
import json
from functools import lru_cache
from pathlib import Path
from PIL import Image
from export_sprites import (_read_slp, pack_sheet, composite_hotspot_images,
                            export_one, resolve_palette)
from player_color import composite_player_masks, pack_masks, save_player_mask


class GraphicExporter:
    def __init__(self, dat, resources, out):
        # DAT omits null graphics: list offsets are NOT graphic IDs.
        self.graphics = {g.graphic_id: g for g in dat.graphics}
        self.resources, self.out = resources, out
        self.out.mkdir(parents=True, exist_ok=True)
        self.root = Path(__file__).resolve().parents[2]
        self.cache, self.report = {}, []

    @lru_cache(maxsize=12)
    def slp(self, slp_id):
        return _read_slp(self.resources, slp_id, 1)

    def export(self, graphic_id, animation=False):
        key = f'g{graphic_id}_{"anim" if animation else "static"}'
        base = 'res://' + (self.out / key).relative_to(self.root).as_posix()
        if key in self.cache: return self.cache[key]
        if (self.out/(key+'.json')).exists():
            metadata = json.loads((self.out/(key+'.json')).read_text(encoding='utf-8'))
            required = [self.out/(key+'.png')]
            if metadata.get('player_color', {}).get('mode') == 'indexed':
                required.append(self.out/metadata['player_color']['mask'])
            complete_groups = int(metadata['frame_count']) == int(metadata['directions']) * int(metadata['frames_per_direction'])
            if complete_groups and all(path.is_file() for path in required):
                self.cache[key] = base
                self._record(graphic_id, base, metadata, cached=True)
                return base
        g = self.graphics[graphic_id]
        refs = [(g, 0, 0)]
        # Deltas already describe every rendered part of a building composite.
        # Descending into part deltas would also include damage/fire overlays.
        refs += [(self.graphics[d.graphic_id], d.offset_x, d.offset_y)
                 for d in g.graphic_deltas if d.graphic_id in self.graphics]
        layers, missing = [], []
        for part, x, y in refs:
            try:
                frames, metas, masks, *_ = self.slp(part.slp_id)
                if not any(im.getbbox() for im in frames): continue
                layers.append((part, x, y, frames, metas, masks))
            except FileNotFoundError:
                missing.append(part.slp_id)
        if not layers and graphic_id == 255:
            base = self.export_farm()
            self.cache[key] = base
            return base
        if not layers:
            raise ValueError(f'Graphic {graphic_id}/{g.name}: no usable SLP layers')
        count = max(len(item[3]) for item in layers) if animation else 1
        fpd = max(1, int(g.frame_count))
        directions = max(1, count // fpd) if animation else 1
        if animation and directions not in (1, 5, 8, 16, 32):
            directions = 5 if count % 5 == 0 else 1
        source_count = count
        # Some legacy SLPs append spare frames after their five directional groups.
        # The DAT animation uses complete groups; do not expose the spare tail.
        count = (count // directions) * directions
        images, all_masks, hotspots = [], [], []
        # Shadows / terrain layers underneath the solid pieces, stable within layer.
        priority = {'TERRAIN':0, 'SHADOW':1, 'UNIT_LOW':2}
        layers.sort(key=lambda x:priority.get(x[0].layer, 3))
        for frame in range(count):
            parts, masks = [], []
            for part,x,y,fs,ms,ks in layers:
                i = frame % len(fs)
                parts.append((fs[i], ms[i].hotspot_x, ms[i].hotspot_y, x, y))
                masks.append(ks[i])
            canvas,hx,hy = composite_hotspot_images(parts)
            mask = composite_player_masks(parts,masks,canvas,hx,hy)
            images.append(canvas); all_masks.append(mask); hotspots.append((hx,hy))
        atlas,cols,rows,fw,fh,pads = pack_sheet(images)
        atlas.save(self.out / (key+'.png'))
        mask_atlas = pack_masks(all_masks,atlas.size,cols,fw,fh,pads)
        color = save_player_mask(mask_atlas,self.out,key,1)
        metadata = dict(key=key,graphic_id=graphic_id,slp_id=g.slp_id,
            source='AoE2 HD DAT graphic + SLP',cols=cols,rows=rows,frame_w=fw,frame_h=fh,
            frame_count=count,source_frame_count=source_count,directions=directions,frames_per_direction=count//directions,
            hotspots=[{'x':p[0]+pad['x'],'y':p[1]+pad['y']} for p,pad in zip(hotspots,pads)],
            player_color=color,includes_shadow=any(x[0].layer=='SHADOW' for x in layers),
            layers=[{'graphic_id':p.graphic_id,'slp_id':p.slp_id,'x':x,'y':y} for p,x,y,*_ in layers],
            missing_slp_ids=missing)
        (self.out/(key+'.json')).write_text(json.dumps(metadata,indent=2)+'\n',encoding='utf-8')
        self.cache[key] = base
        self._record(graphic_id, base, metadata, cached=False)
        print('Exported',key,count,'frames',flush=True)
        return base

    def _record(self, graphic_id, base, metadata, cached):
        self.report.append({'graphic_id':graphic_id,'path':base,
            'frames':int(metadata['frame_count']),
            'missing_slp_ids':metadata.get('missing_slp_ids', []),
            'cached':cached})

    def export_icons(self):
        export_one(resources=self.resources,out_dir=self.out.parent,file_id=50729,
                   key='icons_technologies',category='ui',directions=1,player=1)
        return 'res://assets/sprites/ui/icons_technologies'

    def finish(self):
        (self.out/'import_report.json').write_text(json.dumps(self.report,indent=2)+'\n',encoding='utf-8')

    def export_farm(self):
        # Farms are original terrain textures; their SLP footprint is transparent.
        source = self.resources/'_common/terrain/textures/g_fm1_00_color.png'
        texture = Image.open(source).convert('RGBA').resize((192,192),Image.Resampling.NEAREST)
        # Map the square foundation onto the game's 2:1 isometric ground plane.
        canvas = texture.transform((384,192),Image.Transform.AFFINE,(0.5,1,-96,-0.5,1,96),Image.Resampling.NEAREST)
        key='farm_ground'
        canvas.save(self.out/(key+'.png'))
        meta=dict(key=key,source=source.name,cols=1,rows=1,frame_w=384,frame_h=192,frame_count=1,directions=1,frames_per_direction=1,hotspots=[{'x':192,'y':96}],player_color={'mode':'none'})
        (self.out/(key+'.json')).write_text(json.dumps(meta,indent=2),encoding='utf-8')
        base = 'res://'+(self.out/key).relative_to(self.root).as_posix()
        self._record(255, base, meta, cached=False)
        return base
