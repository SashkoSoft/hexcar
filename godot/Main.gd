extends Node3D
# ======================================================================
# HexCar 3D — полный порт game.html на Godot 4.7 (вид сверху, 3D).
# Логика плиток Труше, дорог-дуг, движения машинок, порталов и режимов
# перенесена 1:1 из game.html; рендер — настоящий 3D с эстакадами.
# ======================================================================

# ---- Геометрия плитки (порт из game.html) ----
var S := 100.0
var A := S * sqrt(3.0) / 2.0
var BAND := 20.0
var COLS := 8
var ROWS := 5
var PAD := BAND + 8.0
var DX := 1.5 * S
var DY := 2.0 * A
var X0 := PAD + S
var Y0 := PAD + A
var FIELD_W := (COLS - 1) * DX + 2.0 * S + 2.0 * PAD
var FIELD_H := (ROWS - 1) * DY + 3.0 * A + 2.0 * PAD

const PAIRS := [[0, 1], [2, 4], [3, 5]]  # три дороги плитки

# ---- 3D-параметры ----
var ROAD_W := BAND
var SLAB := 2.0
var BRIDGE_CLEAR := 13.0           # зазор под мостом (≈ высота машинки + настил)
var BRIDGE_RAMP := 34.0            # длина въезда/съезда моста (ед.)
# на каждую дорогу: список горбов {c=параметр, peak=высота, w=ширина в параметре}
# дорога поднимается ТОЛЬКО там, где проходит НАД другой; снизу остаётся плоской
var road_humps := [[], [], []]

# ---- Машинки ----
var PALETTE := [
	Color8(0xe2, 0x3b, 0x2e), Color8(0x2e, 0x8b, 0xe2), Color8(0x34, 0xa8, 0x53),
	Color8(0xf4, 0xb4, 0x00), Color8(0x9b, 0x30, 0xe2), Color8(0x00, 0xb3, 0xa4),
	Color8(0xff, 0x6f, 0x3c),
]
var SLOW := 55.0
var FAST := 120.0
var RAMP := 12.0
var RECOVER := 0.7
var CRASH_DUR := 0.55
var CAR := 11.0

# ---- Цвета окружения ----
var GRASS_COL := Color8(0x5e, 0xa8, 0x4e)
var ASPH_COL := Color8(0xc6, 0xc6, 0xc6)
var EDGE_COL := Color(1, 1, 1)
var CENTER_COL := Color8(0xff, 0xe0, 0x78)

# ---- Анимация вращения плиток ----
var ROT_SPEED := deg_to_rad(380.0)
var DRAG_STEP := 45.0

# ---- Камера ----
var CAM_DIST_MIN := 350.0
var CAM_DIST_MAX := 3500.0
var CAM_PITCH_MIN := deg_to_rad(8.0)   # ближе к виду сбоку
var CAM_PITCH_MAX := deg_to_rad(85.0)  # почти строго сверху

# ======================================================================
# Структуры данных
# ======================================================================
class Tile:
	var c: int
	var r: int
	var cx: float
	var cy: float
	var m: int
	var pivot: Node3D
	var target_yaw: float
	var roads: Array = []   # 3 MeshInstance3D дорог (для подсветки)

class Car:
	var ti: int = 0
	var frm: int = 0
	var t: float = 0.0
	var size: float = 1.0
	var weight: float = 1.0
	var shape: int = 0
	var color: Color
	var spd: float = 1.0
	var momentum: float = 0.0
	var crashT: float = -1.0
	var dead: bool = false
	var role: String = ""
	var speedK: float = 1.0
	var loopScore: int = 0
	var half_h: float = 4.0
	var node: Node3D

# ======================================================================
# Состояние
# ======================================================================
var BASE_ROADS := []   # 3 базовые дороги (локальные коорд., ориентация 0)
var tiles: Array = []
var cmap := {}          # Vector2i(центр) -> индекс плитки
var PORTAL := {}        # "ti:e" -> {dti, de}
var cars: Array = []
var popups: Array = []  # {node, life, base_y, x}

var mode := "loops"        # loops | chase | bandit
var gameState := "menu"    # menu | play | over
var modeTime := 0.0
var overMsg := ""
var overSub := ""

# режим Кольца
var phase := "idle"        # idle | wait
var waitT := 0.0
var score := 0
var best := 0
var resetT := -1.0
var PRE_WAIT := 1.2
var RESET_DELAY := 0.9
var road_color_map := {}   # "ti:zi" -> Color (подсветка замкнутых кругов)
var colored_keys := {}     # сейчас подсвеченные сегменты
var POP_DUR := 1.1

# ввод
var hover := -1
var drag_tile := -1
var drag_accum := 0.0

# камера (орбитальная, со сглаживанием как в Dorfromantik)
var cam_pivot: Vector3                  # текущая (сглаженная) точка фокуса
var cam_yaw := 0.0
var cam_pitch := deg_to_rad(29.0)       # угол от вертикали
var cam_dist := 1280.0
var tgt_pivot: Vector3                   # целевые значения (к ним плавно идём)
var tgt_yaw := 0.0
var tgt_pitch := deg_to_rad(29.0)
var tgt_dist := 1280.0
var cam_pan := false                     # ПКМ — тащить карту
var cam_rot := false                     # СКМ — вращать

# узлы
var cam: Camera3D
var hover_marker: MeshInstance3D
var ui: CanvasLayer
var menu_panel: Control
var hud_score: Label
var hud_best: Label
var hud_mode: Label
var hud_time: Label
var crash_label: Label
var over_panel: Control
var over_title: Label
var over_sub: Label

# общие ресурсы
var mat_cache := {}
var sphere_mesh: SphereMesh
var cyl_mesh: CylinderMesh
var cone_mesh: CylinderMesh
var road_meshes := []   # ArrayMesh по слоям

# библиотека декора (прототипы дублируются при расстановке)
var lib_tuft: Array = []
var tuft_mm_mesh: ArrayMesh        # общий меш пучка травы для MultiMesh
var tuft_mm_mat: StandardMaterial3D
var lib_flower: Array = []
var lib_bush: Array = []
var lib_tree: Array = []
var lib_rock: Array = []
var GREENS := [
	Color8(0x3f, 0x7a, 0x36), Color8(0x35, 0x6b, 0x2e), Color8(0x48, 0x7f, 0x3a),
	Color8(0x2f, 0x6b, 0x2c), Color8(0x5a, 0x9a, 0x3e), Color8(0x6f, 0xb8, 0x5f),
]
var FLOWER_COLS := [
	Color8(0xff, 0x5d, 0x8f), Color8(0xff, 0xd4, 0x00), Color8(0xff, 0x7a, 0x3c),
	Color8(0xb0, 0x6b, 0xff), Color8(0xff, 0xff, 0xff), Color8(0xff, 0x3b, 0x3b),
	Color8(0x4d, 0xb6, 0xff), Color8(0xff, 0x9e, 0xc7), Color8(0xff, 0xec, 0x5c),
]
var TRUNK_COL := Color8(0x6b, 0x47, 0x2a)

# ======================================================================
func _ready() -> void:
	randomize()
	_build_base_roads()
	_build_bridges()
	_build_environment()
	_build_shared_meshes()
	_build_decor_library()
	_build_road_meshes()
	_build_field()
	_free_protos()
	_build_portals()
	_build_camera()
	_build_hover_marker()
	_build_ui()
	_show_menu()

# ----------------------------------------------------------------------
# Геометрия (порт)
# ----------------------------------------------------------------------
func mpt(k: int, cx: float, cy: float, ang: float) -> Vector2:
	var t := deg_to_rad(60.0 * k + 30.0 + ang)
	return Vector2(cx + A * cos(t), cy + A * sin(t))

func mid_world(cx: float, cy: float, e: int) -> Vector2:
	var t := deg_to_rad(30.0 + 60.0 * e)
	return Vector2(cx + A * cos(t), cy + A * sin(t))

func line_intersect(P: Vector2, d: Vector2, Q: Vector2, e: Vector2) -> Vector2:
	var det := d.x * (-e.y) - (-e.x) * d.y
	var t := ((Q.x - P.x) * (-e.y) - (-e.x) * (Q.y - P.y)) / det
	return P + t * d

func norm2pi(x: float) -> float:
	while x < 0.0:
		x += TAU
	while x >= TAU:
		x -= TAU
	return x

func road_geom(li: int, lj: int, cx: float, cy: float, ang_deg: float) -> Dictionary:
	var Mi := mpt(li, cx, cy, ang_deg)
	var Mj := mpt(lj, cx, cy, ang_deg)
	var thi := deg_to_rad(60.0 * li + 30.0 + ang_deg)
	var thj := deg_to_rad(60.0 * lj + 30.0 + ang_deg)
	var di := Vector2(-sin(thi), cos(thi))
	var dj := Vector2(-sin(thj), cos(thj))
	var C := line_intersect(Mi, di, Mj, dj)
	var R := (Mi - C).length()
	var dO := Vector2(cx - C.x, cy - C.y)
	var L := dO.length()
	var apex := C + R * dO / L
	var a1 := atan2(Mi.y - C.y, Mi.x - C.x)
	var a2 := atan2(Mj.y - C.y, Mj.x - C.x)
	var av := atan2(apex.y - C.y, apex.x - C.x)
	var up := norm2pi(a2 - a1)
	var dv := norm2pi(av - a1)
	var delta := up if dv <= up else up - TAU
	var mm := (int(round(ang_deg / 60.0)) % 6 + 6) % 6
	return {
		"edges": [(li + mm) % 6, (lj + mm) % 6],
		"C": C, "R": R, "a1": a1, "delta": delta, "len": R * abs(delta)
	}

func _build_base_roads() -> void:
	BASE_ROADS.clear()
	for p in PAIRS:
		BASE_ROADS.append(road_geom(p[0], p[1], 0.0, 0.0, 0.0))

# дорога плитки по мировой грани -> {bi, e0, e1}
func road_by_edge(m: int, e: int) -> Dictionary:
	for bi in range(3):
		var wi: int = (PAIRS[bi][0] + m) % 6
		var wj: int = (PAIRS[bi][1] + m) % 6
		if e == wi or e == wj:
			return {"bi": bi, "e0": wi, "e1": wj}
	return {}

func road_of(car: Car) -> Dictionary:
	return road_by_edge(tiles[car.ti].m, car.frm)

func tkey(x: float, y: float) -> Vector2i:
	return Vector2i(int(round(x)), int(round(y)))

func neighbor(ti: int, e: int) -> int:
	var t: Tile = tiles[ti]
	var mid := mid_world(t.cx, t.cy, e)
	var k := tkey(2.0 * mid.x - t.cx, 2.0 * mid.y - t.cy)
	return cmap.get(k, -1)

# ----------------------------------------------------------------------
# Высота эстакады (горб у центра плитки)
# ----------------------------------------------------------------------
func hump(t: float, bi: int) -> float:
	var h := 0.0
	for bump in road_humps[bi]:
		var u: float = (t - bump.c) / bump.w
		var v: float = bump.peak * exp(-u * u)
		if v > h:
			h = v
	return h

# пересечения двух окружностей-дуг -> мировые точки
func _circle_intersections(a: Dictionary, b: Dictionary) -> Array:
	var Ca: Vector2 = a.C
	var Cb: Vector2 = b.C
	var Ra: float = a.R
	var Rb: float = b.R
	var dv := Cb - Ca
	var d := dv.length()
	if d < 1e-6 or d > Ra + Rb or d < abs(Ra - Rb):
		return []
	var x := (Ra * Ra - Rb * Rb + d * d) / (2.0 * d)
	var h2 := Ra * Ra - x * x
	if h2 < 0.0:
		return []
	var hh := sqrt(h2)
	var mid := Ca + dv * (x / d)
	var perp := Vector2(-dv.y, dv.x) / d
	return [mid + perp * hh, mid - perp * hh]

# параметр точки вдоль дуги (0..1); вне дуги — за пределами [0,1]
func _param_on(rd: Dictionary, pt: Vector2) -> float:
	var ang := atan2(pt.y - rd.C.y, pt.x - rd.C.x)
	var rel: float = ang - rd.a1
	while rel < -PI:
		rel += TAU
	while rel > PI:
		rel -= TAU
	return rel / rd.delta

# строим горбы мостов: верхняя дорога (больший индекс) поднимается над нижней
# в точке пересечения; нижняя остаётся плоской. высота = высота нижней + зазор.
func _build_bridges() -> void:
	road_humps = [[], [], []]
	for lo in range(3):
		for hi in range(lo + 1, 3):
			for pt in _circle_intersections(BASE_ROADS[hi], BASE_ROADS[lo]):
				var t_hi := _param_on(BASE_ROADS[hi], pt)
				var t_lo := _param_on(BASE_ROADS[lo], pt)
				if t_hi < -0.02 or t_hi > 1.02 or t_lo < -0.02 or t_lo > 1.02:
					continue
				var bot_h := hump(t_lo, lo)            # высота нижней дороги тут (уже мог быть мост)
				var peak := bot_h + BRIDGE_CLEAR
				var w: float = BRIDGE_RAMP / BASE_ROADS[hi].len
				road_humps[hi].append({"c": t_hi, "peak": peak, "w": w})

# ----------------------------------------------------------------------
# Построение поля
# ----------------------------------------------------------------------
func _build_field() -> void:
	for c in range(COLS):
		for r in range(ROWS):
			var t := Tile.new()
			t.c = c
			t.r = r
			t.cx = X0 + c * DX
			t.cy = Y0 + r * DY + (A if c % 2 == 1 else 0.0)
			t.m = randi() % 6
			t.target_yaw = -deg_to_rad(60.0 * t.m)
			var piv := Node3D.new()
			piv.position = Vector3(t.cx, 0.0, t.cy)
			piv.rotation.y = t.target_yaw
			add_child(piv)
			t.pivot = piv
			# три дороги (общие меши)
			for bi in range(3):
				var mi := MeshInstance3D.new()
				mi.mesh = road_meshes[bi]
				piv.add_child(mi)
				t.roads.append(mi)
			# декор
			_build_decor(t)
			cmap[tkey(t.cx, t.cy)] = tiles.size()
			tiles.append(t)

# ----------------------------------------------------------------------
# Порталы (тороидальное поле) — порт
# ----------------------------------------------------------------------
func _build_portals() -> void:
	var bnd := []
	for ti in range(tiles.size()):
		for e in range(6):
			if neighbor(ti, e) < 0:
				var t: Tile = tiles[ti]
				bnd.append({"ti": ti, "e": e, "mid": mid_world(t.cx, t.cy, e)})
	for b in bnd:
		var th := deg_to_rad(30.0 + 60.0 * b.e)
		var dx := cos(th)
		var dy := sin(th)
		var re: Vector2
		if abs(dx) >= abs(dy):
			re = Vector2(b.mid.x + (FIELD_W if dx < 0 else -FIELD_W), b.mid.y)
		else:
			re = Vector2(b.mid.x, b.mid.y + (FIELD_H if dy < 0 else -FIELD_H))
		var bestD := 1e18
		var best_o = null
		for o in bnd:
			if o == b:
				continue
			var d: float = (o.mid.x - re.x) * (o.mid.x - re.x) + (o.mid.y - re.y) * (o.mid.y - re.y)
			if d < bestD:
				bestD = d
				best_o = o
		PORTAL[str(b.ti) + ":" + str(b.e)] = {"dti": best_o.ti, "de": best_o.e}

# ======================================================================
# Машинки — логика (порт)
# ======================================================================
func pick_color() -> Color:
	var used := {}
	for c in cars:
		used[c.color] = true
	var av := []
	for col in PALETTE:
		if not used.has(col):
			av.append(col)
	var pool: Array = av if av.size() > 0 else PALETTE
	return pool[randi() % pool.size()]

func make_car(size: float, weight: float, shape: int) -> Car:
	var c := Car.new()
	c.size = size
	c.weight = weight
	c.shape = shape
	c.color = pick_color()
	c.spd = 1.0
	c.half_h = max(6.0, 8.0 * size) * 0.5
	_build_car_node(c)
	return c

func place_random(car: Car) -> void:
	car.ti = randi() % tiles.size()
	var bi := randi() % 3
	var m: int = tiles[car.ti].m
	car.frm = (PAIRS[bi][randi() % 2] + m) % 6
	car.t = 0.0
	car.spd = 0.0
	car.momentum = 0.0

func same_level(a: Car, b: Car) -> bool:
	if a.ti != b.ti:
		return true
	return road_of(a).bi == road_of(b).bi

# Локальный transform машинки (в системе пивота плитки)
func car_local_xf(car: Car) -> Transform3D:
	var rd := road_of(car)
	var b: Dictionary = BASE_ROADS[rd.bi]
	var local_from: int = (car.frm - tiles[car.ti].m + 6) % 6
	var li: int = PAIRS[rd.bi][0]
	var fromA: bool = local_from == li
	var startA: float = b.a1 if fromA else b.a1 + b.delta
	var dir := 1.0 if fromA else -1.0
	var ang: float = startA + dir * b.delta * car.t
	var px: float = b.C.x + b.R * cos(ang)
	var py: float = b.C.y + b.R * sin(ang)
	var heading: float = ang + sign(b.delta) * dir * PI / 2.0
	var h := hump(car.t, rd.bi) + car.half_h + 1.0
	# тангаж: нос вверх/вниз по уклону дороги (производная высоты вдоль движения)
	var eps := 0.0035
	var dhdt := (hump(car.t + eps, rd.bi) - hump(car.t - eps, rd.bi)) / (2.0 * eps)
	var slope: float = dir * dhdt / b.len
	var p := atan(slope)
	var ch := cos(heading)
	var sh := sin(heading)
	var cp := cos(p)
	var sp := sin(p)
	var fwd := Vector3(ch * cp, sp, sh * cp)   # локальный +X (вперёд), наклонён по уклону
	var lat := Vector3(-sh, 0.0, ch)            # локальный +Z (вбок, горизонтальный — без крена)
	var up := lat.cross(fwd)                     # локальный +Y
	return Transform3D(Basis(fwd, up, lat), Vector3(px, h, py))

func car_world_xf(car: Car) -> Transform3D:
	return tiles[car.ti].pivot.global_transform * car_local_xf(car)

func car_world_pos(car: Car) -> Vector2:
	var o := car_world_xf(car).origin
	return Vector2(o.x, o.z)

func compute_loop(car: Car) -> Dictionary:
	var set := {}
	var ti := car.ti
	var frm := car.frm
	var guard := 0
	while guard < 400:
		guard += 1
		var rb := road_by_edge(tiles[ti].m, frm)
		if rb.is_empty():
			return {"set": set, "closed": false}
		set[str(ti) + ":" + str(rb.bi)] = true
		var toEdge: int = rb.e1 if frm == rb.e0 else rb.e0
		var nb := neighbor(ti, toEdge)
		if nb < 0:
			return {"set": set, "closed": false}
		ti = nb
		frm = (toEdge + 3) % 6
		if ti == car.ti and frm == car.frm:
			return {"set": set, "closed": true}
	return {"set": set, "closed": false}

func advance(car: Car, dt: float) -> void:
	if car.crashT > 0.0:
		car.crashT -= dt
		if car.crashT <= 0.0:
			car.dead = true
		return
	car.spd = min(1.0, car.spd + dt / RECOVER)
	var mcap := 1.0 if mode == "loops" else 6.0
	car.momentum = min(mcap, car.momentum + dt / (RAMP * car.weight))
	var speed := (SLOW + (FAST - SLOW) * car.momentum) / car.weight * car.speedK
	var move := speed * car.spd * dt
	var guard := 0
	while move > 0.0 and guard < 40:
		guard += 1
		var rd := road_of(car)
		var ln: float = BASE_ROADS[rd.bi].len
		var remain := (1.0 - car.t) * ln
		if move < remain:
			car.t += move / ln
			break
		move -= remain
		var toEdge: int = rd.e1 if car.frm == rd.e0 else rd.e0
		var nb := neighbor(car.ti, toEdge)
		if nb >= 0:
			car.ti = nb
			car.frm = (toEdge + 3) % 6
			car.t = 0.0
		else:
			var p = PORTAL.get(str(car.ti) + ":" + str(toEdge), null)
			if p != null:
				car.ti = p.dti
				car.frm = p.de
				car.t = 0.0
			else:
				car.frm = toEdge
				car.t = 0.0

func rotate_tile(idx: int, dir: int) -> void:
	var t: Tile = tiles[idx]
	t.m = (t.m + dir + 6) % 6
	t.target_yaw -= deg_to_rad(60.0) * dir
	for c in cars:
		if c.ti == idx:
			c.frm = (c.frm + dir + 6) % 6
			c.spd = 0.0
			c.momentum = 0.0

# ======================================================================
# Спавн / сброс (порт)
# ======================================================================
func shuffle_field() -> void:
	for t in tiles:
		t.m = randi() % 6
		t.target_yaw = -deg_to_rad(60.0 * t.m)
		t.pivot.rotation.y = t.target_yaw

func add_starter() -> void:
	var c := make_car(1.0, 1.0, 0)
	c.ti = -1
	for i in range(tiles.size()):
		if tiles[i].c == COLS >> 1 and tiles[i].r == ROWS >> 1:
			c.ti = i
			break
	if c.ti < 0:
		c.ti = 0
	c.frm = (PAIRS[1][0] + tiles[c.ti].m) % 6
	cars.append(c)

func reset_game() -> void:
	_clear_cars()
	phase = "idle"
	waitT = 0.0
	resetT = -1.0
	score = 0
	_clear_popups()
	shuffle_field()
	add_starter()

func spawn_racer(role: String) -> Car:
	var c := make_car(1.05 if role == "police" else 1.0, 1.0, 1 if role == "police" else 0)
	c.role = role
	c.color = Color8(0x1f, 0x6f, 0xeb) if role == "police" else Color8(0xe2, 0x3b, 0x2e)
	c.speedK = 1.28 if role == "police" else 1.0
	_recolor_car(c)
	for tries in range(200):
		place_random(c)
		var ok := true
		var p := car_world_pos(c)
		for o in cars:
			var q := car_world_pos(o)
			if p.distance_squared_to(q) < pow(FIELD_W * 0.4, 2.0):
				ok = false
				break
		if ok or tries > 150:
			break
	cars.append(c)
	return c

func spawn_next() -> void:
	var car := make_car(0.8 + randf() * 0.8, 0.6 + randf() * 1.2, 0 if randf() < 0.5 else 1)
	for tries in range(200):
		place_random(car)
		if compute_loop(car).closed:
			continue
		var p := car_world_pos(car)
		var near := false
		for o in cars:
			var q := car_world_pos(o)
			if p.distance_squared_to(q) < 45.0 * 45.0:
				near = true
				break
		if not near:
			break
	cars.append(car)

func start_mode(m: String) -> void:
	mode = m
	gameState = "play"
	modeTime = 0.0
	_clear_cars()
	_clear_popups()
	phase = "idle"
	waitT = 0.0
	resetT = -1.0
	score = 0
	shuffle_field()
	if m == "loops":
		add_starter()
	else:
		spawn_racer("bandit")
		spawn_racer("police")
	menu_panel.visible = false
	over_panel.visible = false

# ======================================================================
# Шаги режимов (порт)
# ======================================================================
func step_loops(dt: float) -> void:
	if resetT > 0.0:
		resetT -= dt
		if resetT <= 0.0:
			reset_game()
	for c in cars:
		advance(c, dt)
	for i in range(cars.size() - 1, -1, -1):
		if cars[i].dead:
			_remove_car(i)
	if cars.size() == 0 and resetT < 0.0:
		add_starter()
		phase = "idle"
	score = 0
	road_color_map = {}
	var loop_sets := []
	var closed_flags := []
	for i in range(cars.size()):
		var c: Car = cars[i]
		var L := compute_loop(c)
		loop_sets.append(L.set)
		closed_flags.append(L.closed)
		var cur := 0
		if L.closed:
			var cells := {}
			for k in L.set.keys():
				cells[k.split(":")[0]] = true
				road_color_map[k] = c.color   # подсветка сегмента цветом машинки
			cur = cells.size() * cells.size()
			score += cur
		if cur != c.loopScore:
			var p := car_world_xf(c).origin
			add_popup(p, cur - c.loopScore)
		c.loopScore = cur
	if score > best:
		best = score
	if resetT < 0.0:
		var armed := cars.size() - 1
		if phase == "idle" and armed >= 0 and closed_flags[armed]:
			phase = "wait"
			waitT = PRE_WAIT
		elif phase == "wait":
			waitT -= dt
			if waitT <= 0.0:
				spawn_next()
				phase = "idle"
		var done := false
		for i in range(cars.size()):
			if done:
				break
			for j in range(i + 1, cars.size()):
				var a: Car = cars[i]
				var b: Car = cars[j]
				if a.crashT > 0.0 or b.crashT > 0.0 or not same_level(a, b):
					continue
				var pa := car_world_pos(a)
				var pb := car_world_pos(b)
				var rr := (a.size + b.size) * CAR * 0.75
				if pa.distance_squared_to(pb) < rr * rr:
					a.crashT = CRASH_DUR
					b.crashT = CRASH_DUR
					resetT = RESET_DELAY
					done = true
					break

func step_chase(dt: float) -> void:
	modeTime += dt
	for c in cars:
		advance(c, dt)
	if cars.size() >= 2 and same_level(cars[0], cars[1]):
		var a: Car = cars[0]
		var b: Car = cars[1]
		var pa := car_world_pos(a)
		var pb := car_world_pos(b)
		var rr := (a.size + b.size) * CAR * 0.85
		if pa.distance_squared_to(pb) < rr * rr:
			gameState = "over"
			if mode == "chase":
				overMsg = "Поймал бандита!"
				overSub = "за %.1f c" % modeTime
			else:
				overMsg = "Пойман!"
				overSub = "Продержался %.1f c" % modeTime
			_show_over()

# подсветка дорог замкнутых кругов цветом машинки (тонируем асфальт, surface 0)
func _road_tint_mat(col: Color) -> StandardMaterial3D:
	var key := "roadtint|" + str(col)
	if mat_cache.has(key):
		return mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col.lerp(Color.WHITE, 0.4)
	m.roughness = 0.7
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 1.8
	mat_cache[key] = m
	return m

func _apply_road_colors(map: Dictionary) -> void:
	for k in colored_keys.keys():
		if not map.has(k):
			var p: PackedStringArray = k.split(":")
			tiles[int(p[0])].roads[int(p[1])].set_surface_override_material(0, null)
	for k in map.keys():
		var p: PackedStringArray = k.split(":")
		tiles[int(p[0])].roads[int(p[1])].set_surface_override_material(0, _road_tint_mat(map[k]))
	colored_keys = map

# ======================================================================
# Главный цикл
# ======================================================================
func _process(dt: float) -> void:
	dt = min(0.05, dt)
	# доводка поворота плиток
	for t in tiles:
		if t.pivot.rotation.y != t.target_yaw:
			t.pivot.rotation.y = move_toward(t.pivot.rotation.y, t.target_yaw, ROT_SPEED * dt)

	if gameState == "play":
		if mode == "loops":
			step_loops(dt)
		else:
			step_chase(dt)

	if not (gameState == "play" and mode == "loops"):
		road_color_map = {}
	_apply_road_colors(road_color_map)

	# позиции машинок
	for c in cars:
		if c.node == null:
			continue
		if c.crashT > 0.0:
			c.node.scale = Vector3.ONE * max(0.05, c.crashT / CRASH_DUR)
		c.node.transform = car_world_xf(c)

	_update_hover(dt)
	_update_popups(dt)
	_update_ui()
	_camera_keys(dt)
	_smooth_camera(dt)
	update_camera()

# ======================================================================
# Ввод
# ======================================================================
func _update_hover(_dt: float) -> void:
	if drag_tile >= 0:
		hover = drag_tile
	elif gameState == "play":
		hover = _pick_tile()
	else:
		hover = -1
	if hover >= 0:
		hover_marker.visible = true
		var t: Tile = tiles[hover]
		hover_marker.position = Vector3(t.cx, 1.5, t.cy)
	else:
		hover_marker.visible = false

func _pick_tile() -> int:
	if cam == null:
		return -1
	var mp := get_viewport().get_mouse_position()
	var origin := cam.project_ray_origin(mp)
	var dir := cam.project_ray_normal(mp)
	if abs(dir.y) < 1e-6:
		return -1
	var tt := -origin.y / dir.y
	if tt < 0.0:
		return -1
	var hit := origin + dir * tt
	var px := hit.x
	var py := hit.z
	for i in range(tiles.size()):
		if _point_in_hex(px, py, tiles[i]):
			return i
	return -1

func _point_in_hex(px: float, py: float, t: Tile) -> bool:
	for k in range(6):
		var a1 := deg_to_rad(60.0 * k)
		var a2 := deg_to_rad(60.0 * (k + 1))
		var x1 := t.cx + S * cos(a1)
		var y1 := t.cy + S * sin(a1)
		var x2 := t.cx + S * cos(a2)
		var y2 := t.cy + S * sin(a2)
		if (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1) < 0.0:
			return false
	return true

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var b: int = event.button_index
		if b == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_at(0.88)
		elif b == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_at(1.0 / 0.88)
		elif b == MOUSE_BUTTON_RIGHT:
			cam_pan = event.pressed
		elif b == MOUSE_BUTTON_MIDDLE:
			cam_rot = event.pressed
		elif b == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if gameState == "over":
					_show_menu()
					return
				if gameState == "play" and hover >= 0:
					drag_tile = hover
					drag_accum = 0.0
			else:
				drag_tile = -1
	elif event is InputEventMouseMotion:
		if cam_pan:
			_pan_drag(event.relative)
		elif cam_rot:
			tgt_yaw += event.relative.x * 0.006
			tgt_pitch = clamp(tgt_pitch - event.relative.y * 0.004, CAM_PITCH_MIN, CAM_PITCH_MAX)
		elif drag_tile >= 0:
			drag_accum += event.relative.x
			while drag_accum >= DRAG_STEP:
				rotate_tile(drag_tile, 1)
				drag_accum -= DRAG_STEP
			while drag_accum <= -DRAG_STEP:
				rotate_tile(drag_tile, -1)
				drag_accum += DRAG_STEP
	elif event is InputEventKey and event.pressed and not event.echo:
		if gameState == "play" and hover >= 0:
			if event.keycode == KEY_LEFT or event.keycode == KEY_A:
				rotate_tile(hover, -1)
			elif event.keycode == KEY_RIGHT or event.keycode == KEY_S:
				rotate_tile(hover, 1)

# ======================================================================
# Материалы / общие меши
# ======================================================================
func get_mat(col: Color, rough := 0.85, emit := 0.0) -> StandardMaterial3D:
	var key := str(col) + "|" + str(rough) + "|" + str(emit)
	if mat_cache.has(key):
		return mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	if emit > 0.0:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = emit
	mat_cache[key] = m
	return m

func _build_shared_meshes() -> void:
	sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = 1.0
	sphere_mesh.height = 2.0
	sphere_mesh.radial_segments = 8
	sphere_mesh.rings = 5
	cyl_mesh = CylinderMesh.new()
	cyl_mesh.top_radius = 1.0
	cyl_mesh.bottom_radius = 1.0
	cyl_mesh.height = 1.0
	cyl_mesh.radial_segments = 8
	cone_mesh = CylinderMesh.new()
	cone_mesh.top_radius = 0.0
	cone_mesh.bottom_radius = 1.0
	cone_mesh.height = 1.0
	cone_mesh.radial_segments = 9

# ======================================================================
# Меши дорог (общие для всех плиток — базовая ориентация)
# ======================================================================
func _build_road_meshes() -> void:
	road_meshes.clear()
	var asph := get_mat(ASPH_COL, 0.95)
	asph.cull_mode = BaseMaterial3D.CULL_DISABLED
	var side := get_mat(ASPH_COL.darkened(0.25), 0.95)
	side.cull_mode = BaseMaterial3D.CULL_DISABLED
	var white := get_mat(EDGE_COL, 0.6, 0.25)
	white.cull_mode = BaseMaterial3D.CULL_DISABLED
	var yellow := get_mat(CENTER_COL, 0.6, 0.3)
	yellow.cull_mode = BaseMaterial3D.CULL_DISABLED
	for bi in range(3):
		var b: Dictionary = BASE_ROADS[bi]
		var n: int = max(8, int(round(b.len / 7.0)))
		var L_top := []
		var R_top := []
		var normals := []
		for i in range(n + 1):
			var tt := float(i) / float(n)
			var ang: float = b.a1 + b.delta * tt
			var nrm := Vector2(cos(ang), sin(ang))
			var pt: Vector2 = b.C + b.R * nrm
			var y := hump(tt, bi)
			L_top.append(Vector3(pt.x + nrm.x * ROAD_W * 0.5, y, pt.y + nrm.y * ROAD_W * 0.5))
			R_top.append(Vector3(pt.x - nrm.x * ROAD_W * 0.5, y, pt.y - nrm.y * ROAD_W * 0.5))
			normals.append(nrm)
		var mesh := ArrayMesh.new()
		# поверхность + бортики
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in range(n):
			_quad(st, L_top[i], L_top[i + 1], R_top[i + 1], R_top[i], Vector3.UP)
			# левый бортик
			var lb0: Vector3 = L_top[i] - Vector3(0, SLAB, 0)
			var lb1: Vector3 = L_top[i + 1] - Vector3(0, SLAB, 0)
			var ln: Vector3 = Vector3(normals[i].x, 0, normals[i].y)
			_quad(st, L_top[i], lb0, lb1, L_top[i + 1], ln)
			# правый бортик
			var rb0: Vector3 = R_top[i] - Vector3(0, SLAB, 0)
			var rb1: Vector3 = R_top[i + 1] - Vector3(0, SLAB, 0)
			_quad(st, R_top[i + 1], rb1, rb0, R_top[i], -ln)
		st.commit(mesh)
		mesh.surface_set_material(0, asph)
		# краевые линии (белые)
		var off := ROAD_W * 0.5 - 3.5
		var sw := SurfaceTool.new()
		sw.begin(Mesh.PRIMITIVE_TRIANGLES)
		_line_ribbon(sw, b, bi, n, off, 1.8)
		_line_ribbon(sw, b, bi, n, -off, 1.8)
		sw.commit(mesh)
		mesh.surface_set_material(1, white)
		# центральная линия — прерывистая (как настоящая разметка)
		var sy := SurfaceTool.new()
		sy.begin(Mesh.PRIMITIVE_TRIANGLES)
		_dash_ribbon(sy, b, bi, 0.0, 1.7, 9.0, 7.0)
		sy.commit(mesh)
		mesh.surface_set_material(2, yellow)
		road_meshes.append(mesh)

func _line_ribbon(st: SurfaceTool, b: Dictionary, bi: int, n: int, off: float, w: float) -> void:
	var prevL := Vector3.ZERO
	var prevR := Vector3.ZERO
	for i in range(n + 1):
		var tt := float(i) / float(n)
		var ang: float = b.a1 + b.delta * tt
		var nrm := Vector2(cos(ang), sin(ang))
		var pt: Vector2 = b.C + (b.R + off) * nrm
		var y := hump(tt, bi) + 0.5
		var l := Vector3(pt.x + nrm.x * w * 0.5, y, pt.y + nrm.y * w * 0.5)
		var rr := Vector3(pt.x - nrm.x * w * 0.5, y, pt.y - nrm.y * w * 0.5)
		if i > 0:
			_quad(st, prevL, l, rr, prevR, Vector3.UP)
		prevL = l
		prevR = rr

func _dash_ribbon(st: SurfaceTool, b: Dictionary, bi: int, off: float, w: float, dash_len: float, gap_len: float) -> void:
	var total: float = b.len
	var nn: int = max(10, int(total / 3.0))
	var period := dash_len + gap_len
	var prevL := Vector3.ZERO
	var prevR := Vector3.ZERO
	var prev_on := false
	for i in range(nn + 1):
		var tt := float(i) / float(nn)
		var s := total * tt
		var on := fmod(s, period) < dash_len
		var ang: float = b.a1 + b.delta * tt
		var nrm := Vector2(cos(ang), sin(ang))
		var pt: Vector2 = b.C + (b.R + off) * nrm
		var y := hump(tt, bi) + 0.55
		var l := Vector3(pt.x + nrm.x * w * 0.5, y, pt.y + nrm.y * w * 0.5)
		var rr := Vector3(pt.x - nrm.x * w * 0.5, y, pt.y - nrm.y * w * 0.5)
		if i > 0 and on and prev_on:
			_quad(st, prevL, l, rr, prevR, Vector3.UP)
		prevL = l
		prevR = rr
		prev_on = on

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, nrm: Vector3) -> void:
	st.set_normal(nrm); st.add_vertex(a)
	st.set_normal(nrm); st.add_vertex(b)
	st.set_normal(nrm); st.add_vertex(c)
	st.set_normal(nrm); st.add_vertex(a)
	st.set_normal(nrm); st.add_vertex(c)
	st.set_normal(nrm); st.add_vertex(d)

# ======================================================================
# Декор (порт makeDecor + 3D-меши)
# ======================================================================
func _dist_to_roads(px: float, py: float) -> float:
	var m := 1e9
	for rd in BASE_ROADS:
		var dx: float = px - rd.C.x
		var dy: float = py - rd.C.y
		var rr := sqrt(dx * dx + dy * dy)
		var dd: float
		if _ang_within(atan2(dy, dx), rd.a1, rd.delta):
			dd = abs(rr - rd.R)
		else:
			var a2: float = rd.a1 + rd.delta
			var p1 := Vector2(rd.C.x + rd.R * cos(rd.a1), rd.C.y + rd.R * sin(rd.a1))
			var p2 := Vector2(rd.C.x + rd.R * cos(a2), rd.C.y + rd.R * sin(a2))
			dd = min(Vector2(px, py).distance_to(p1), Vector2(px, py).distance_to(p2))
		if dd < m:
			m = dd
	return m

func _ang_within(ang: float, a1: float, delta: float) -> bool:
	var x := ang - a1
	while x < -PI:
		x += TAU
	while x > PI:
		x -= TAU
	if delta >= 0.0:
		return x >= 0.0 and x <= delta
	return x <= 0.0 and x >= delta

# ---- Текстура травы (процедурная, бесшовная) ----
func _seamless(noise: FastNoiseLite, x: int, y: int, sz: int) -> float:
	var fx := float(x) / sz
	var fy := float(y) / sz
	var a := noise.get_noise_2d(x, y)
	var b := noise.get_noise_2d(x - sz, y)
	var c := noise.get_noise_2d(x, y - sz)
	var d := noise.get_noise_2d(x - sz, y - sz)
	return a * (1 - fx) * (1 - fy) + b * fx * (1 - fy) + c * (1 - fx) * fy + d * fx * fy

func _make_grass_material() -> StandardMaterial3D:
	var sz := 256
	var img := Image.create(sz, sz, false, Image.FORMAT_RGB8)
	var coarse := FastNoiseLite.new()
	coarse.noise_type = FastNoiseLite.TYPE_SIMPLEX
	coarse.frequency = 0.018
	coarse.seed = randi()
	var fine := FastNoiseLite.new()
	fine.noise_type = FastNoiseLite.TYPE_SIMPLEX
	fine.frequency = 0.11
	fine.seed = randi()
	for yy in sz:
		for xx in sz:
			var s: float = clamp(_seamless(coarse, xx, yy, sz) * 0.5 + 0.5, 0.0, 1.0)
			var f: float = clamp(_seamless(fine, xx, yy, sz) * 0.5 + 0.5, 0.0, 1.0)
			var col := GRASS_COL.darkened(0.18).lerp(GRASS_COL.lightened(0.14), s)
			col = col.lerp(GRASS_COL.lightened(0.20), f * 0.25)
			img.set_pixel(xx, yy, col)
	# крапинки: травинки/росинки/камешки
	for i in range(1700):
		var x := randi() % sz
		var y := randi() % sz
		var r := randf()
		var c: Color
		if r < 0.6:
			c = GRASS_COL.darkened(0.30)
		elif r < 0.86:
			c = GRASS_COL.lightened(0.28)
		else:
			c = Color8(0xcd, 0xe1, 0xb9)
		img.set_pixel(x, y, c)
	var tex := ImageTexture.create_from_image(img)
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.roughness = 1.0
	var rep := (FIELD_W + 400.0) / 150.0
	m.uv1_scale = Vector3(rep, rep, 1.0)
	return m

# ---- Вспомогательные конструкторы декора ----
func _mi(mesh: Mesh, mat: Material, pos: Vector3, scl: Vector3, shadow: bool) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.mesh = mesh
	n.material_override = mat
	n.position = pos
	n.scale = scl
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return n

func _leaf_mat(col: Color) -> StandardMaterial3D:
	var key := "leaf|" + str(col)
	if mat_cache.has(key):
		return mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.9
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat_cache[key] = m
	return m

func _make_tuft_mesh(_col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var blades := 6
	for k in range(blades):
		var ang := float(k) / blades * TAU + 0.5
		var bx := cos(ang) * 1.2
		var bz := sin(ang) * 1.2
		var h := 5.5 + float(k % 3) * 1.8
		var lean := 1.5
		var px := -sin(ang) * 0.7
		var pz := cos(ang) * 0.7
		var b0 := Vector3(bx - px, 0, bz - pz)
		var b1 := Vector3(bx + px, 0, bz + pz)
		var tip := Vector3(bx + cos(ang) * lean, h, bz + sin(ang) * lean)
		st.set_normal(Vector3.UP); st.add_vertex(b0)
		st.set_normal(Vector3.UP); st.add_vertex(b1)
		st.set_normal(Vector3.UP); st.add_vertex(tip)
	var m := ArrayMesh.new()
	st.commit(m)
	return m

func _make_tuft(col: Color) -> Node3D:
	var r := Node3D.new()
	r.add_child(_mi(_make_tuft_mesh(col), _leaf_mat(col), Vector3.ZERO, Vector3.ONE, false))
	return r

func _make_rock(col: Color, sx: float, sy: float, sz: float) -> Node3D:
	var r := Node3D.new()
	r.add_child(_mi(sphere_mesh, get_mat(col), Vector3(0, sy * 0.45, 0), Vector3(sx, sy, sz), false))
	return r

func _make_flower(col: Color) -> Node3D:
	var r := Node3D.new()
	r.add_child(_mi(cyl_mesh, _leaf_mat(GREENS[0]), Vector3(0, 2.6, 0), Vector3(0.5, 5.2, 0.5), false))
	var petal_mat := get_mat(col, 0.6)
	var n := 5
	for k in range(n):
		var ang := float(k) / n * TAU
		var pet := _mi(sphere_mesh, petal_mat, Vector3(cos(ang) * 1.7, 5.4, sin(ang) * 1.7), Vector3(1.7, 0.6, 1.0), false)
		pet.rotation.y = ang
		r.add_child(pet)
	r.add_child(_mi(sphere_mesh, get_mat(Color8(0xff, 0xc4, 0x33), 0.5), Vector3(0, 5.6, 0), Vector3(1.1, 0.9, 1.1), false))
	return r

func _make_bush(col: Color) -> Node3D:
	var r := Node3D.new()
	var offs := [Vector3(-2.4, 3.0, 0.4), Vector3(2.4, 3.0, 0.4), Vector3(0, 4.4, -1.0), Vector3(0.2, 3.2, 1.6)]
	for i in range(offs.size()):
		var c: Color = col if i % 2 == 0 else col.lightened(0.08)
		r.add_child(_mi(sphere_mesh, get_mat(c), offs[i], Vector3(3.4, 3.2, 3.4), false))
	return r

func _make_round_tree(green: Color) -> Node3D:
	var r := Node3D.new()
	r.add_child(_mi(cyl_mesh, get_mat(TRUNK_COL), Vector3(0, 7.0, 0), Vector3(2.4, 14, 2.4), true))
	r.add_child(_mi(sphere_mesh, get_mat(green), Vector3(0, 18.0, 0), Vector3(11.5, 12.0, 11.5), true))
	r.add_child(_mi(sphere_mesh, get_mat(green.lightened(0.10)), Vector3(3.5, 22.0, 2.0), Vector3(7.2, 7.2, 7.2), true))
	r.add_child(_mi(sphere_mesh, get_mat(green.darkened(0.08)), Vector3(-3.8, 20.0, -2.2), Vector3(6.6, 6.6, 6.6), true))
	return r

func _make_pine(green: Color) -> Node3D:
	var r := Node3D.new()
	r.add_child(_mi(cyl_mesh, get_mat(TRUNK_COL), Vector3(0, 5.0, 0), Vector3(2.0, 10, 2.0), true))
	r.add_child(_mi(cone_mesh, get_mat(green), Vector3(0, 15, 0), Vector3(11, 13, 11), true))
	r.add_child(_mi(cone_mesh, get_mat(green.lightened(0.06)), Vector3(0, 22, 0), Vector3(8, 11, 8), true))
	r.add_child(_mi(cone_mesh, get_mat(green.lightened(0.12)), Vector3(0, 28, 0), Vector3(5.4, 8, 5.4), true))
	return r

func _free_protos() -> void:
	# прототипы декора больше не нужны (поле уже собрано через duplicate)
	for arr in [lib_tuft, lib_flower, lib_bush, lib_tree, lib_rock]:
		for p in arr:
			p.queue_free()
		arr.clear()

func _build_decor_library() -> void:
	# общий меш + материал травы (цвет задаётся per-instance через MultiMesh)
	tuft_mm_mesh = _make_tuft_mesh(Color.WHITE)
	tuft_mm_mat = StandardMaterial3D.new()
	tuft_mm_mat.albedo_color = Color.WHITE
	tuft_mm_mat.vertex_color_use_as_albedo = true
	tuft_mm_mat.roughness = 0.9
	tuft_mm_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for fc in FLOWER_COLS:
		lib_flower.append(_make_flower(fc))
	for c in GREENS:
		lib_bush.append(_make_bush(c))
	lib_tree.append(_make_round_tree(GREENS[3]))
	lib_tree.append(_make_round_tree(GREENS[1]))
	lib_tree.append(_make_round_tree(GREENS[4]))
	lib_tree.append(_make_pine(GREENS[3]))
	lib_tree.append(_make_pine(GREENS[0]))
	lib_rock.append(_make_rock(Color8(0xb9, 0xb2, 0xa4), 4.0, 2.2, 4.0))
	lib_rock.append(_make_rock(Color8(0x9a, 0x93, 0x85), 3.4, 2.0, 3.6))

func _build_decor(t: Tile) -> void:
	var HW := BAND * 0.5
	var items := []
	# очень густая трава — через MultiMesh (один draw-call на плитку)
	var gx := []
	var gc := []
	var gp := 0
	var gg := 0
	while gp < 300 and gg < 2400:
		gg += 1
		var a := randf() * TAU
		var rad := sqrt(randf()) * A * 1.03
		var x := cos(a) * rad
		var y := sin(a) * rad
		if _dist_to_roads(x, y) - HW > 1.0:
			var tsc := 0.7 + randf() * 1.0
			var tb := Basis(Vector3.UP, randf() * TAU).scaled(Vector3.ONE * tsc)
			gx.append(Transform3D(tb, Vector3(x, 0, y)))
			gc.append(GREENS[randi() % GREENS.size()])
			gp += 1
	if gx.size() > 0:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = tuft_mm_mesh
		mm.instance_count = gx.size()
		for i in range(gx.size()):
			mm.set_instance_transform(i, gx[i])
			mm.set_instance_color(i, gc[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = tuft_mm_mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		t.pivot.add_child(mmi)
	# много разных цветочков по всей траве
	var placed := 0
	var guard := 0
	while placed < 14 and guard < 600:
		guard += 1
		var a := randf() * TAU
		var rad := sqrt(randf()) * A * 0.98
		var x := cos(a) * rad
		var y := sin(a) * rad
		if _dist_to_roads(x, y) - HW > 2.0:
			items.append({"type": "flower", "x": x, "y": y, "sc": 0.85 + randf() * 0.8, "rot": randf() * TAU})
			placed += 1
	# камешки вдоль дороги
	placed = 0
	guard = 0
	while placed < 6 and guard < 300:
		guard += 1
		var a := randf() * TAU
		var rad := randf() * A * 0.86
		var x := cos(a) * rad
		var y := sin(a) * rad
		var off := _dist_to_roads(x, y) - HW
		if off > 2.0 and off < 12.0:
			items.append({"type": "rock", "x": x, "y": y, "sc": 0.65 + randf() * 0.7, "rot": randf() * TAU})
			placed += 1
	# цветы, кусты, деревья по удалённости от дороги
	placed = 0
	guard = 0
	while placed < 14 and guard < 500:
		guard += 1
		var a := randf() * TAU
		var rad := randf() * A * 0.85
		var x := cos(a) * rad
		var y := sin(a) * rad
		var off := _dist_to_roads(x, y) - HW
		if off < 2.0:
			continue
		var mix := randf()
		var type := "flower"
		if off < 12.0:
			type = "flower" if mix < 0.8 else "rock"
		elif off < 22.0:
			type = "flower" if mix < 0.45 else ("bush" if mix < 0.78 else "tree")
		else:
			type = "tree" if mix < 0.6 else ("bush" if mix < 0.85 else "flower")
		var sc := 0.9 + randf() * 0.8
		if type == "tree":
			sc = 0.8 + randf() * 0.5
		items.append({"type": type, "x": x, "y": y, "sc": sc, "rot": randf() * TAU})
		placed += 1
	for it in items:
		_spawn_decor_node(t, it)

func _spawn_decor_node(t: Tile, it: Dictionary) -> void:
	var proto: Node3D = null
	match it.type:
		"flower":
			proto = lib_flower[randi() % lib_flower.size()]
		"bush":
			proto = lib_bush[randi() % lib_bush.size()]
		"tree":
			proto = lib_tree[randi() % lib_tree.size()]
		_:
			proto = lib_rock[randi() % lib_rock.size()]
	var n := proto.duplicate() as Node3D
	n.position = Vector3(it.x, 0.0, it.y)
	n.scale = Vector3.ONE * float(it.sc)
	n.rotation.y = it.rot
	t.pivot.add_child(n)

# ======================================================================
# Машинки — 3D-узлы
# ======================================================================
func _build_car_node(c: Car) -> void:
	var root := Node3D.new()
	var L := CAR * c.size
	var length := L * 1.8
	var width := L * 1.1
	var height: float = max(5.0, 5.5 * c.size)
	c.half_h = height * 0.5
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(length, height, width)
	body.mesh = bm
	body.material_override = get_mat(c.color, 0.4)
	body.name = "body"
	root.add_child(body)
	# крыша/кабина
	var cab := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(length * 0.5, height * 0.6, width * 0.8)
	cab.mesh = cm
	cab.material_override = get_mat(c.color.darkened(0.2), 0.4)
	cab.position = Vector3(-length * 0.05, height * 0.55, 0)
	cab.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(cab)
	# лобовое
	var ws := MeshInstance3D.new()
	var wm := BoxMesh.new()
	wm.size = Vector3(width * 0.18, height * 0.55, width * 0.66)
	ws.mesh = wm
	ws.material_override = get_mat(Color(0.85, 0.92, 1.0), 0.1, 0.0)
	ws.position = Vector3(length * 0.16, height * 0.4, 0)
	ws.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ws)
	if c.role == "police":
		var l1 := MeshInstance3D.new()
		var l1m := BoxMesh.new()
		l1m.size = Vector3(width * 0.2, height * 0.3, width * 0.25)
		l1.mesh = l1m
		l1.material_override = get_mat(Color8(0xee, 0x11, 0x11), 0.3, 1.5)
		l1.position = Vector3(0, height * 0.7, -width * 0.18)
		root.add_child(l1)
		var l2 := MeshInstance3D.new()
		l2.mesh = l1m
		l2.material_override = get_mat(Color8(0x11, 0x66, 0xff), 0.3, 1.5)
		l2.position = Vector3(0, height * 0.7, width * 0.18)
		root.add_child(l2)
	# фары (ночь): прожектор + светящаяся лампа спереди, красный фонарь сзади
	var hl_y := height * 0.15
	var beam := Vector3(0.96, -0.30, 0.0).normalized()
	var lz := -beam
	var lx := Vector3.UP.cross(lz).normalized()
	var ly := lz.cross(lx)
	var lamp_mat := get_mat(Color(1.0, 0.95, 0.8), 0.2, 4.0)
	var tail_mat := get_mat(Color(1.0, 0.12, 0.06), 0.3, 3.0)
	for s in [-1.0, 1.0]:
		var spot := SpotLight3D.new()
		spot.light_color = Color(1.0, 0.95, 0.78)
		spot.light_energy = 20.0
		spot.spot_range = 240.0
		spot.spot_angle = 32.0
		spot.spot_angle_attenuation = 0.9
		spot.spot_attenuation = 0.9
		spot.shadow_enabled = false
		spot.transform = Transform3D(Basis(lx, ly, lz), Vector3(length * 0.5, hl_y, s * width * 0.30))
		root.add_child(spot)
		var lamp := MeshInstance3D.new()
		var lampm := BoxMesh.new()
		lampm.size = Vector3(width * 0.10, height * 0.20, width * 0.18)
		lamp.mesh = lampm
		lamp.material_override = lamp_mat
		lamp.position = Vector3(length * 0.5, hl_y, s * width * 0.30)
		lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(lamp)
		var tl := MeshInstance3D.new()
		var tlm := BoxMesh.new()
		tlm.size = Vector3(width * 0.08, height * 0.16, width * 0.16)
		tl.mesh = tlm
		tl.material_override = tail_mat
		tl.position = Vector3(-length * 0.5, hl_y, s * width * 0.30)
		tl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(tl)
	add_child(root)
	c.node = root

func _recolor_car(c: Car) -> void:
	if c.node == null:
		return
	var body := c.node.get_node_or_null("body")
	if body:
		body.material_override = get_mat(c.color, 0.4)

func _remove_car(i: int) -> void:
	var c: Car = cars[i]
	if c.node:
		c.node.queue_free()
	cars.remove_at(i)

func _clear_cars() -> void:
	for c in cars:
		if c.node:
			c.node.queue_free()
	cars.clear()

# ======================================================================
# Всплывающие очки (Label3D)
# ======================================================================
func add_popup(pos: Vector3, d: int) -> void:
	if d == 0:
		return
	var lbl := Label3D.new()
	lbl.text = ("+" if d > 0 else "−") + str(abs(d))
	lbl.font_size = 96
	lbl.outline_size = 24
	lbl.modulate = Color8(0x2e, 0xcc, 0x40) if d > 0 else Color8(0xe2, 0x3b, 0x2e)
	lbl.outline_modulate = Color(1, 1, 1)
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.pixel_size = 0.35
	lbl.position = pos + Vector3(0, 20, 0)
	add_child(lbl)
	popups.append({"node": lbl, "life": 0.0, "base_y": pos.y + 20.0})

func _update_popups(dt: float) -> void:
	for i in range(popups.size() - 1, -1, -1):
		var p = popups[i]
		p.life += dt
		var k: float = p.life / POP_DUR
		var lbl: Label3D = p.node
		lbl.position.y = p.base_y + k * 40.0
		lbl.modulate.a = max(0.0, 1.0 - k)
		var s := 1.0 + k * 0.6
		lbl.scale = Vector3(s, s, s)
		if p.life > POP_DUR:
			lbl.queue_free()
			popups.remove_at(i)

func _clear_popups() -> void:
	for p in popups:
		p.node.queue_free()
	popups.clear()

# ======================================================================
# Окружение / камера / маркер
# ======================================================================
func _build_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color8(0x05, 0x07, 0x14)
	sky_mat.sky_horizon_color = Color8(0x12, 0x18, 0x30)
	sky_mat.ground_horizon_color = Color8(0x10, 0x14, 0x26)
	sky_mat.ground_bottom_color = Color8(0x04, 0x05, 0x0c)
	sky.sky_material = sky_mat
	env.sky = sky
	# ночь: холодный, но различимый ambient (лунный свет)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color8(0x32, 0x3d, 0x63)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# свечение для фар/подсветки кругов
	env.glow_enabled = true
	env.glow_intensity = 1.0
	env.glow_bloom = 0.2
	env.glow_hdr_threshold = 0.85
	# объёмный туман выключен: при дальней камере он затягивал всё поле в дымку
	env.volumetric_fog_enabled = false
	we.environment = env
	add_child(we)

	# луна (холодный направленный свет)
	var moon := DirectionalLight3D.new()
	moon.rotation = Vector3(deg_to_rad(-55.0), deg_to_rad(35.0), 0.0)
	moon.light_color = Color8(0x7d, 0x92, 0xd6)
	moon.light_energy = 0.38
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 3000.0
	add_child(moon)

	# трава
	var grass := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(FIELD_W + 400.0, FIELD_H + 400.0)
	grass.mesh = pm
	grass.material_override = _make_grass_material()
	grass.position = Vector3(FIELD_W * 0.5, -0.5, FIELD_H * 0.5)
	add_child(grass)

func _build_camera() -> void:
	cam = Camera3D.new()
	cam.fov = 45.0
	cam.far = 8000.0
	add_child(cam)
	cam_pivot = Vector3(FIELD_W * 0.5, 0.0, FIELD_H * 0.5)
	tgt_pivot = cam_pivot
	tgt_yaw = cam_yaw
	tgt_pitch = cam_pitch
	tgt_dist = cam_dist
	update_camera()

func update_camera() -> void:
	if cam == null:
		return
	var dir := Vector3(0.0, cos(cam_pitch), sin(cam_pitch)).rotated(Vector3.UP, cam_yaw)
	cam.position = cam_pivot + dir * cam_dist
	cam.look_at(cam_pivot, Vector3.UP)

func _smooth_camera(dt: float) -> void:
	var a: float = 1.0 - exp(-14.0 * dt)   # плавная доводка к цели
	cam_pivot = cam_pivot.lerp(tgt_pivot, a)
	cam_yaw = lerp(cam_yaw, tgt_yaw, a)
	cam_pitch = lerp(cam_pitch, tgt_pitch, a)
	cam_dist = lerp(cam_dist, tgt_dist, a)

# точка на земле (y=0) под экранной координатой
func _ground_point(screen: Vector2) -> Vector3:
	var o := cam.project_ray_origin(screen)
	var d := cam.project_ray_normal(screen)
	if abs(d.y) < 1e-6:
		return tgt_pivot
	var tt := -o.y / d.y
	if tt < 0.0:
		return tgt_pivot
	return o + d * tt

func _clamp_pivot() -> void:
	tgt_pivot.x = clamp(tgt_pivot.x, -500.0, FIELD_W + 500.0)
	tgt_pivot.z = clamp(tgt_pivot.z, -500.0, FIELD_H + 500.0)
	cam_pivot.x = clamp(cam_pivot.x, -500.0, FIELD_W + 500.0)
	cam_pivot.z = clamp(cam_pivot.z, -500.0, FIELD_H + 500.0)

# ПКМ-перетаскивание: точка под курсором «прилипает» к курсору
func _pan_drag(rel: Vector2) -> void:
	var mp := get_viewport().get_mouse_position()
	var cur := _ground_point(mp)
	var prev := _ground_point(mp - rel)
	var delta := prev - cur
	delta.y = 0.0
	tgt_pivot += delta
	cam_pivot += delta
	_clamp_pivot()

# зум к точке под курсором (колесо)
func _zoom_at(factor: float) -> void:
	var g := _ground_point(get_viewport().get_mouse_position())
	g.y = 0.0
	var old := tgt_dist
	tgt_dist = clamp(old * factor, CAM_DIST_MIN, CAM_DIST_MAX)
	var ratio := tgt_dist / old
	tgt_pivot = g + (tgt_pivot - g) * ratio
	_clamp_pivot()

func _camera_keys(dt: float) -> void:
	var yaw_sp := 1.6 * dt
	var pitch_sp := 1.2 * dt
	var zoom_sp := 1.8 * dt
	if Input.is_key_pressed(KEY_Q):
		tgt_yaw -= yaw_sp
	if Input.is_key_pressed(KEY_E):
		tgt_yaw += yaw_sp
	if Input.is_key_pressed(KEY_R):
		tgt_pitch = clamp(tgt_pitch - pitch_sp, CAM_PITCH_MIN, CAM_PITCH_MAX)
	if Input.is_key_pressed(KEY_F):
		tgt_pitch = clamp(tgt_pitch + pitch_sp, CAM_PITCH_MIN, CAM_PITCH_MAX)
	if Input.is_key_pressed(KEY_Z):
		tgt_dist = clamp(tgt_dist * (1.0 - zoom_sp), CAM_DIST_MIN, CAM_DIST_MAX)
	if Input.is_key_pressed(KEY_X):
		tgt_dist = clamp(tgt_dist * (1.0 + zoom_sp), CAM_DIST_MIN, CAM_DIST_MAX)

func _build_hover_marker() -> void:
	hover_marker = MeshInstance3D.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var inr := S * 0.9
	var outr := S * 1.0
	for k in range(6):
		var a1 := deg_to_rad(60.0 * k)
		var a2 := deg_to_rad(60.0 * (k + 1))
		var i1 := Vector3(inr * cos(a1), 0, inr * sin(a1))
		var o1 := Vector3(outr * cos(a1), 0, outr * sin(a1))
		var i2 := Vector3(inr * cos(a2), 0, inr * sin(a2))
		var o2 := Vector3(outr * cos(a2), 0, outr * sin(a2))
		_quad(st, o1, o2, i2, i1, Vector3.UP)
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	var mat := get_mat(Color8(0xff, 0x95, 0x00), 0.4, 0.8)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = 0.7
	mesh.surface_set_material(0, mat)
	hover_marker.mesh = mesh
	hover_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hover_marker.visible = false
	add_child(hover_marker)

# ======================================================================
# UI
# ======================================================================
func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)

	# --- HUD ---
	hud_score = _mk_label(16, 12, 34, true)
	hud_best = _mk_label(16, 54, 18, true)
	hud_mode = _mk_label(16, 12, 26, true)
	hud_time = _mk_label(16, 48, 22, true)
	crash_label = _mk_label(0, 0, 56, true)
	crash_label.add_theme_color_override("font_color", Color8(0xdd, 0x11, 0x11))
	crash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	crash_label.anchor_left = 0.5
	crash_label.anchor_right = 0.5
	crash_label.anchor_top = 0.28
	crash_label.position = Vector2(0, 0)
	crash_label.text = "АВАРИЯ!"
	crash_label.visible = false

	# --- Меню ---
	menu_panel = Control.new()
	menu_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.add_child(menu_panel)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_panel.add_child(dim)
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_CENTER)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 14)
	vb.anchor_left = 0.5
	vb.anchor_right = 0.5
	vb.anchor_top = 0.5
	vb.anchor_bottom = 0.5
	vb.offset_left = -220
	vb.offset_right = 220
	vb.offset_top = -190
	vb.offset_bottom = 220
	menu_panel.add_child(vb)
	var title := Label.new()
	title.text = "HexCar 3D"
	title.add_theme_font_size_override("font_size", 56)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var sub := Label.new()
	sub.text = "Выбери режим"
	sub.add_theme_font_size_override("font_size", 18)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(sub)
	var menu_items := [
		["loops", "Кольца", "Загоняй машинки в кольца, копи очки"],
		["chase", "Погоня", "Догони бандита своей полицейской"],
		["bandit", "Бандит", "Уходи от полиции как можно дольше"],
	]
	for mi in menu_items:
		var btn := Button.new()
		btn.text = mi[1] + "  —  " + mi[2]
		btn.custom_minimum_size = Vector2(440, 60)
		btn.add_theme_font_size_override("font_size", 22)
		var key: String = mi[0]
		btn.pressed.connect(func(): start_mode(key))
		vb.add_child(btn)

	# --- Экран конца ---
	over_panel = Control.new()
	over_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.add_child(over_panel)
	var odim := ColorRect.new()
	odim.color = Color(0, 0, 0, 0.55)
	odim.set_anchors_preset(Control.PRESET_FULL_RECT)
	over_panel.add_child(odim)
	over_title = Label.new()
	over_title.add_theme_font_size_override("font_size", 58)
	over_title.add_theme_color_override("font_color", Color8(0xff, 0xd4, 0x00))
	over_title.set_anchors_preset(Control.PRESET_CENTER)
	over_title.anchor_left = 0.0
	over_title.anchor_right = 1.0
	over_title.anchor_top = 0.40
	over_title.anchor_bottom = 0.40
	over_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	over_panel.add_child(over_title)
	over_sub = Label.new()
	over_sub.add_theme_font_size_override("font_size", 24)
	over_sub.anchor_left = 0.0
	over_sub.anchor_right = 1.0
	over_sub.anchor_top = 0.52
	over_sub.anchor_bottom = 0.52
	over_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	over_panel.add_child(over_sub)
	var hint := Label.new()
	hint.text = "клик — в меню"
	hint.add_theme_font_size_override("font_size", 18)
	hint.anchor_left = 0.0
	hint.anchor_right = 1.0
	hint.anchor_top = 0.60
	hint.anchor_bottom = 0.60
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	over_panel.add_child(hint)
	over_panel.visible = false

	# --- подсказка по камере (всегда видна) ---
	var cam_hint := Label.new()
	cam_hint.text = "Камера:  ПКМ — тащить  ·  СКМ — вращать/наклон  ·  колесо — зум к курсору  ·  Q/E/R/F/Z/X"
	cam_hint.add_theme_font_size_override("font_size", 14)
	cam_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	cam_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	cam_hint.add_theme_constant_override("outline_size", 4)
	cam_hint.anchor_left = 0.0
	cam_hint.anchor_right = 1.0
	cam_hint.anchor_top = 1.0
	cam_hint.anchor_bottom = 1.0
	cam_hint.offset_top = -28
	cam_hint.offset_bottom = -6
	cam_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui.add_child(cam_hint)

func _mk_label(x: float, y: float, size: int, shadow: bool) -> Label:
	var l := Label.new()
	l.position = Vector2(x, y)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(1, 1, 1))
	if shadow:
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		l.add_theme_constant_override("outline_size", 6)
	ui.add_child(l)
	return l

func _show_menu() -> void:
	gameState = "menu"
	_clear_cars()
	_clear_popups()
	menu_panel.visible = true
	over_panel.visible = false

func _show_over() -> void:
	over_title.text = overMsg
	over_sub.text = overSub
	over_panel.visible = true

func _update_ui() -> void:
	var playing := gameState == "play"
	var loops := mode == "loops"
	hud_score.visible = playing and loops
	hud_best.visible = playing and loops
	hud_mode.visible = playing and not loops
	hud_time.visible = playing and not loops
	crash_label.visible = playing and loops and resetT > 0.0
	if playing:
		if loops:
			hud_score.text = "Очки: " + str(score)
			hud_best.text = "Рекорд: " + str(best)
		else:
			hud_mode.text = "Догони бандита!" if mode == "chase" else "Уходи от полиции!"
			hud_time.text = "Время: %.1f c" % modeTime



