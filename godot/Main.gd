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
	var deco := {}          # сезон → Node3D-контейнер декора (строятся лениво)
	var items: Array = []   # сохранённый список декора (позиции/типы для всех сезонов)
	var grass_x: Array = [] # трансформы пучков травы (цвет задаётся по сезону)

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
	var lights: Array = []   # SpotLight3D фар (для смены пресета на лету)

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

# бот: автоповорот плиток ради самых больших петель (хилл-климбинг + пертурбации)
var bot_active := false
var bot_timer := 0.0
var BOT_INTERVAL := 0.08          # пауза между ходами бота (с)
var bot_best_val := -1            # лучший достигнутый счёт (Σ плиток² по петлям)
var bot_best_max := 0             # размер самой большой петли в лучшей конфигурации
var bot_best_m: Array = []        # снимок ориентаций лучшей конфигурации
var bot_no_improve := 0           # локальных оптимумов подряд без нового рекорда
var bot_moves := 0                # всего ходов бота за запуск
var bot_max_loop := 0             # текущая самая большая петля (для подписи)
var bot_btn: Button

# ---- Пресеты оформления (свет/фары/свечение/небо) ----
# текущие настройки; применяются через _apply_look(), сохраняются/читаются с диска
var look := {}
var env: Environment
var moon: DirectionalLight3D
var sky_mat: ShaderMaterial
const LOOK_PATH := "user://look.cfg"
var PRESETS := {
	"Ночь": {
		"ambient_color": Color(0.118, 0.149, 0.259), "ambient_energy": 0.28,
		"moon_color": Color(0.525, 0.608, 0.871), "moon_energy": 0.25,
		"glow_intensity": 1.1, "glow_bloom": 0.25, "glow_threshold": 0.8,
		"sky_top": Color(0.003, 0.005, 0.016), "sky_horizon": Color(0.018, 0.026, 0.058), "star": 1.0,
		"hl_energy": 38.0, "hl_range": 420.0, "hl_angle": 30.0, "hl_color": Color(1.0, 0.95, 0.78),
		"highlight_emission": 1.8, "hl_white": 0.4,
		# стиль рендера
		"tonemap": "filmic", "exposure": 1.0, "contrast": 1.05, "saturation": 1.12, "brightness": 1.0,
		"sun": 0.0,
	},
	"Сумерки": {
		"ambient_color": Color(0.32, 0.30, 0.42), "ambient_energy": 0.7,
		"moon_color": Color(0.95, 0.72, 0.55), "moon_energy": 0.7,
		"glow_intensity": 0.9, "glow_bloom": 0.15, "glow_threshold": 0.9,
		"sky_top": Color(0.10, 0.10, 0.22), "sky_horizon": Color(0.55, 0.35, 0.30), "star": 0.35,
		"hl_energy": 16.0, "hl_range": 300.0, "hl_angle": 30.0, "hl_color": Color(1.0, 0.96, 0.82),
		"highlight_emission": 1.5, "hl_white": 0.18,
		"tonemap": "agx", "exposure": 1.0, "contrast": 1.02, "saturation": 1.08, "brightness": 1.0,
		"sun": 0.5,
	},
	"День": {
		"ambient_color": Color(0.50, 0.59, 0.74), "ambient_energy": 0.30,
		"moon_color": Color(1.0, 0.80, 0.50), "moon_energy": 1.9,
		"glow_intensity": 0.25, "glow_bloom": 0.05, "glow_threshold": 1.1,
		"sky_top": Color(0.20, 0.40, 0.72), "sky_horizon": Color(0.66, 0.78, 0.88), "star": 0.0,
		"hl_energy": 5.0, "hl_range": 180.0, "hl_angle": 30.0, "hl_color": Color(1.0, 0.97, 0.85),
		"highlight_emission": 1.6, "hl_white": 0.0,
		# тёплое солнце + чёткие тени (низкий ambient), AgX гасит пересветы
		"tonemap": "agx", "exposure": 0.95, "contrast": 1.15, "saturation": 1.08, "brightness": 1.0,
		"sun": 1.0,
	},
}
var flash_label: Label
var flash_t := 0.0
var current_preset := ""        # имя активного пресета (для подсветки кнопки)
var style_panel: Control
var style_buttons := {}         # имя -> Button

# художественный пост-эффект (полноэкранный шейдер поверх 3D)
var current_style := 0          # 0 нет·1 тун·2 акварель·3 гуашь·4 карандаш·5 карандаш 2·6 контур+цвет·7 тун градиент·8 контур+цвет+тун
const STYLE_NAMES := ["Нет", "Тун", "Акварель", "Гуашь", "Карандаш", "Карандаш 2", "Контур+цвет", "Тун градиент", "Контур+цвет+тун"]
# параметры Canny (low/high — пороги, blur — денойз, paper — зерно, mult — multiply на цвет, toon — база через тун-градиент)
const CANNY_CFG := {
	4: {"low": 0.14, "high": 0.36, "blur": 1.5, "line": 0.85, "paper": 0.0, "mult": 0.0, "toon": 0.0},  # расширенный — больше линий
	5: {"low": 0.09, "high": 0.26, "blur": 1.2, "line": 0.90, "paper": 0.0, "mult": 0.0, "toon": 0.0},  # широкий — максимум деталей
	6: {"low": 0.10, "high": 0.28, "blur": 1.3, "line": 0.95, "paper": 0.0, "mult": 1.0, "toon": 0.0},  # контур ×цветной рендер
	8: {"low": 0.10, "high": 0.28, "blur": 1.3, "line": 0.95, "paper": 0.0, "mult": 1.0, "toon": 1.0, "thick": 2.5},  # контур ×цвет ×тун-градиент + жирный контур
}
var fx_layer: CanvasLayer
var fx_rect: ColorRect
var fx_mat: ShaderMaterial
var style_fx_buttons := {}      # индекс -> Button

# погода (переключаемая в меню) — настоящие 3D-частицы, падают на карту
var weather := 0                 # 0 нет · 1 дождь · 2 снег
const WEATHER_NAMES := ["Нет", "Дождь", "Снег"]
var rain_ps: GPUParticles3D
var snow_ps: GPUParticles3D
var weather_btn: Button

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
var lib_snow_tree: Array = []   # зимние деревья «в снегу»
var lib_snow_mound: Array = []  # сугробы/заснеженные кусты-камни
var lib_autumn_tree: Array = [] # осенние деревья (жёлто-красная листва)
var lib_autumn_bush: Array = []
var lib_spring_tree: Array = [] # весенние деревья (свежая зелень + цветение)
var proto_holder: Node3D        # скрытый родитель прототипов декора (вместо free)
var ground: MeshInstance3D      # плоскость земли (трава ↔ снег по сезону)
var grass_mat: ShaderMaterial
var snow_white_mat: StandardMaterial3D   # общий матовый снег для шапок/сугробов
var ground_mats := {}           # сезон → материал земли (ленивый кэш)
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
# осенняя/весенняя палитры
var AUTUMN := [
	Color8(0xd9, 0x8e, 0x2b), Color8(0xc4, 0x5b, 0x28), Color8(0xb0, 0x36, 0x2a),
	Color8(0xe0, 0xb0, 0x3a), Color8(0x9a, 0x6b, 0x2b),
]
var AUTUMN_GRASS := [
	Color8(0x8f, 0x90, 0x50), Color8(0xa3, 0x96, 0x52), Color8(0x76, 0x82, 0x48),
	Color8(0xb0, 0x92, 0x4c), Color8(0x6f, 0x7e, 0x44),
]
var SPRING_GREEN := [
	Color8(0x8f, 0xcf, 0x5a), Color8(0xa3, 0xd9, 0x66), Color8(0x77, 0xc2, 0x4d), Color8(0xb6, 0xe0, 0x6e),
]
var BLOSSOM := [Color8(0xf7, 0xc5, 0xd8), Color8(0xff, 0xfa, 0xfc), Color8(0xf2, 0x9c, 0xc0)]

# сезон поля (отдельно от времени суток) + сезонная цветокоррекция света
var SEASONS := ["Лето", "Осень", "Зима", "Весна"]
var season := "Лето"
var season_buttons := {}
# множители цвета/тона, накладываются поверх пресета времени суток
var SEASON_GRADE := {
	"Лето":  {"amb": Color(1, 1, 1),        "sky": Color(1, 1, 1),        "light": Color(1, 1, 1),        "sat": 1.0,  "con": 1.0,  "bri": 1.0},
	"Осень": {"amb": Color(1.03, 0.99, 0.88),"sky": Color(1.05, 0.97, 0.86),"light": Color(1.03, 0.99, 0.88),"sat": 0.96, "con": 1.02, "bri": 1.0},
	"Зима":  {"amb": Color(0.90, 0.96, 1.10),"sky": Color(0.94, 1.0, 1.10), "light": Color(0.90, 0.96, 1.08),"sat": 0.88, "con": 1.05, "bri": 1.04},
	"Весна": {"amb": Color(1.0, 1.04, 0.97), "sky": Color(1.0, 1.03, 1.0),  "light": Color(1.0, 1.03, 0.96), "sat": 1.09, "con": 1.0,  "bri": 1.02},
}

# ======================================================================
func _ready() -> void:
	randomize()
	look = PRESETS["Ночь"].duplicate(true)   # пресет по умолчанию
	current_preset = "Ночь"
	_build_base_roads()
	_build_bridges()
	_build_environment()
	_build_shared_meshes()
	_build_decor_library()
	_build_road_meshes()
	_build_field()
	_build_portals()
	_build_camera()
	_build_hover_marker()
	_build_fx()
	_build_weather()   # 3D-частицы дождя/снега над полем
	_build_ui()
	_show_menu()
	load_look()   # если есть сохранённые настройки на диске — применить их

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

# ======================================================================
# Бот: крутит плитки, чтобы получились самые большие петли
# ======================================================================
# Декомпозиция всех дорог поля на петли. Полудуга (ti,e) → преемник (сосед, (выход+3)%6);
# это перестановка, её циклы — петли. score = Σ (число плиток в петле)² по замкнутым.
func _loop_score() -> Dictionary:
	var visited := {}
	var total := 0
	var mx := 0
	for ti in range(tiles.size()):
		for e in range(6):
			var sk := str(ti) + ":" + str(e)
			if visited.has(sk):
				continue
			var cti := ti
			var ce := e
			var tile_set := {}
			var closed := false
			var guard := 0
			while guard < 1000:
				guard += 1
				var hk := str(cti) + ":" + str(ce)
				if visited.has(hk):
					closed = (hk == sk)   # вернулись в старт → замкнуто
					break
				visited[hk] = true
				var rb := road_by_edge(tiles[cti].m, ce)
				if rb.is_empty():
					break
				tile_set[cti] = true
				var toEdge: int = rb.e1 if ce == rb.e0 else rb.e0
				var nb := neighbor(cti, toEdge)
				if nb < 0:
					break                 # упёрлись в край — петля разомкнута
				cti = nb
				ce = (toEdge + 3) % 6
			if closed:
				var n: int = tile_set.size()
				total += n * n
				if n > mx:
					mx = n
	return {"score": total, "max": mx}

# лучший одиночный поворот: какую плитку и в какую ориентацию, чтобы счёт вырос максимально
func _bot_best_move() -> Dictionary:
	var base: int = _loop_score().score
	var best_gain := 0
	var best_ti := -1
	var best_m := 0
	for ti in range(tiles.size()):
		var orig: int = tiles[ti].m
		for mm in range(6):
			if mm == orig:
				continue
			tiles[ti].m = mm
			var sc: int = _loop_score().score
			if sc - base > best_gain:
				best_gain = sc - base
				best_ti = ti
				best_m = mm
		tiles[ti].m = orig
	return {"ti": best_ti, "m": best_m, "gain": best_gain}

# повернуть плитку до нужной ориентации кратчайшим путём (через rotate_tile — с анимацией)
func _set_tile_m(ti: int, target_m: int) -> void:
	var cur: int = tiles[ti].m
	var delta: int = (target_m - cur + 6) % 6
	if delta == 0:
		return
	var dir := 1 if delta <= 3 else -1
	var steps: int = delta if delta <= 3 else 6 - delta
	for s in range(steps):
		rotate_tile(ti, dir)

func _snapshot_m() -> Array:
	var a := []
	for t in tiles:
		a.append(t.m)
	return a

func _restore_m(a: Array) -> void:
	for i in range(min(a.size(), tiles.size())):
		_set_tile_m(i, a[i])

func toggle_bot() -> void:
	if not (gameState == "play" and mode == "loops"):
		return
	bot_active = not bot_active
	if bot_active:
		bot_best_val = -1
		bot_best_max = 0
		bot_no_improve = 0
		bot_moves = 0
		bot_timer = 0.0
		_flash("Бот: ищет самые большие петли…")
	else:
		_flash("Бот: выкл")
	_update_bot_btn()

func _update_bot_btn() -> void:
	if bot_btn == null:
		return
	if bot_active:
		bot_btn.text = "Бот: петля %d ⟳" % bot_max_loop
		bot_btn.modulate = Color(1, 0.85, 0.35)
	else:
		bot_btn.text = "Бот: петли (B)"
		bot_btn.modulate = Color(1, 1, 1)

func _bot_tick(dt: float) -> void:
	bot_timer -= dt
	if bot_timer > 0.0:
		return
	bot_timer = BOT_INTERVAL
	var cur := _loop_score()
	bot_max_loop = cur.max
	if cur.score > bot_best_val:        # новый рекорд — запоминаем конфигурацию
		bot_best_val = cur.score
		bot_best_max = cur.max
		bot_best_m = _snapshot_m()
		bot_no_improve = 0
	var mv := _bot_best_move()
	bot_moves += 1
	if mv.gain > 0:
		_set_tile_m(mv.ti, mv.m)        # жадный шаг вверх
	else:
		# локальный оптимум: пертурбация, чтобы выбраться и поискать петлю крупнее
		bot_no_improve += 1
		if bot_no_improve > 6 or bot_moves > 800:
			_restore_m(bot_best_m)      # вернуть лучшее найденное и остановиться
			bot_active = false
			_flash("Бот: готово · самая большая петля — %d плиток" % bot_best_max)
		else:
			for k in range(3):
				rotate_tile(randi() % tiles.size(), 1 if randi() % 2 == 0 else -1)
	_update_bot_btn()

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
	bot_active = false
	_update_bot_btn()
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
	if resetT < 0.0 and not bot_active:   # пока бот перестраивает поле — без спавна/аварий/сброса
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
	# Ночью подсветка читается за счёт свечения (неон); днём свечения почти нет,
	# поэтому база должна быть НАСЫЩЕННОЙ краской, а не блёкло-белой — иначе тускло
	# и пересвечено. hl_white управляет подмесом к белому (ночь — больше, день — 0),
	# а emission = сам цвет (а не белый) держит насыщенность и при ярком свете.
	var emit: float = look.get("highlight_emission", 1.8)
	var white_mix: float = look.get("hl_white", 0.4)
	var key := "roadtint|" + str(col) + "|" + str(emit) + "|" + str(white_mix)
	if mat_cache.has(key):
		return mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col.lerp(Color.WHITE, white_mix)
	m.roughness = 0.55
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = emit
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
			if bot_active:
				_bot_tick(dt)
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
	if flash_t > 0.0:
		flash_t -= dt
		flash_label.visible = true
		flash_label.modulate.a = clamp(flash_t, 0.0, 1.0)
	elif flash_label.visible:
		flash_label.visible = false
	_camera_keys(dt)
	_smooth_camera(dt)
	update_camera()

# ======================================================================
# Ввод
# ======================================================================
func _update_hover(_dt: float) -> void:
	if gameState == "play":
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
		elif b == MOUSE_BUTTON_LEFT and event.pressed:
			# ЛКМ — только плитки: клик = поворот +60°, Shift+клик = −60°
			if gameState == "over":
				_show_menu()
			elif gameState == "play" and hover >= 0:
				rotate_tile(hover, -1 if event.shift_pressed else 1)
	elif event is InputEventMouseMotion:
		# любое перетаскивание мышью — только камера
		if cam_pan:
			_pan_drag(event.relative)
		elif cam_rot:
			tgt_yaw += event.relative.x * 0.006
			tgt_pitch = clamp(tgt_pitch - event.relative.y * 0.004, CAM_PITCH_MIN, CAM_PITCH_MAX)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				apply_preset("Ночь")
			KEY_2:
				apply_preset("Сумерки")
			KEY_3:
				apply_preset("День")
			KEY_F5:
				save_look()
			KEY_F9:
				load_look()
			KEY_B:
				toggle_bot()
			_:
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

# земля как ShaderMaterial: тайлированная процедурная текстура + мягкое
# ЭЛЛИПТИЧЕСКОЕ растворение вокруг игрового поля. Земля плотная только над
# зоной плиток, а дальше широко и КРУГЛО (не квадратом) уходит в прозрачность —
# на виде сверху нет ни прямоугольного «острова» статичной земли, ни резкой кромки.
# Изолинии — эллипсы (нормируем смещение от центра на полуразмер поля), поэтому
# на виде сверху переход не квадратный. Плоскость заметно больше поля, чтобы
# затухание ушло в 0 ещё ДО её прямоугольного края — самой кромки не видно.
const GROUND_FADE_START := 1.05   # доля поля: до сюда земля плотная (вплотную к кромке поля)
const GROUND_FADE_END := 1.95     # здесь земля полностью растворилась в фон
const GROUND_SHADER := """
shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_burley;
uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 rep = vec2(1.0);
uniform float rough = 1.0;
uniform vec2 plane_size = vec2(1.0);
uniform vec2 field_half = vec2(1.0);
uniform float fade_start = 1.05;
uniform float fade_end = 1.95;
void fragment() {
	ALBEDO = texture(tex, UV * rep).rgb;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	vec2 off = (UV - 0.5) * plane_size;   // смещение от центра поля (мир)
	vec2 n = off / field_half;            // 1.0 на середине кромки поля
	float d = length(n);                  // эллиптические изолинии — без углов/квадрата
	ALPHA = 1.0 - smoothstep(fade_start, fade_end, d);
}
"""

func _ground_plane_size() -> Vector2:
	return Vector2(FIELD_W * GROUND_FADE_END + 200.0, FIELD_H * GROUND_FADE_END + 200.0)

# базовый цвет земли сезона — фон у кромки подгоняется под него
func _ground_base_color(s: String) -> Color:
	match s:
		"Зима": return Color(0.90, 0.93, 0.98)
		"Осень": return Color8(0x5c, 0x72, 0x4c)
		"Весна": return Color8(0x6f, 0xc0, 0x52)
		_: return GRASS_COL

func _wrap_ground(tex: Texture2D, rough: float) -> ShaderMaterial:
	var ps := _ground_plane_size()
	var sh := Shader.new()
	sh.code = GROUND_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("rep", ps / 150.0)
	m.set_shader_parameter("rough", rough)
	m.set_shader_parameter("plane_size", ps)
	m.set_shader_parameter("field_half", Vector2(FIELD_W * 0.5, FIELD_H * 0.5))
	m.set_shader_parameter("fade_start", GROUND_FADE_START)
	m.set_shader_parameter("fade_end", GROUND_FADE_END)
	return m

func _make_grass_material() -> ShaderMaterial:
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
	return _wrap_ground(tex, 1.0)

func _make_snow_ground_material() -> ShaderMaterial:
	var sz := 256
	var img := Image.create(sz, sz, false, Image.FORMAT_RGB8)
	var coarse := FastNoiseLite.new()
	coarse.noise_type = FastNoiseLite.TYPE_SIMPLEX
	coarse.frequency = 0.012
	coarse.seed = randi()
	var base := Color(0.90, 0.93, 0.98)   # снег с лёгкой голубизной
	for yy in sz:
		for xx in sz:
			var s: float = clamp(_seamless(coarse, xx, yy, sz) * 0.5 + 0.5, 0.0, 1.0)
			# мягкие сугробы: голубоватые впадины ↔ почти белые гребни
			var col := base.darkened(0.10).lerp(Color(1.0, 1.0, 1.0), s)
			img.set_pixel(xx, yy, col)
	# редкие искорки-блёстки
	for i in range(900):
		var x := randi() % sz
		var y := randi() % sz
		img.set_pixel(x, y, Color(1.0, 1.0, 1.0) if randf() < 0.7 else Color(0.82, 0.88, 0.98))
	var tex := ImageTexture.create_from_image(img)
	return _wrap_ground(tex, 0.82)

func _field_mat(base: Color, flecks: Array) -> ShaderMaterial:
	# обобщённый материал земли: шумовая основа + крапинки (для осени/весны)
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
			var col := base.darkened(0.18).lerp(base.lightened(0.14), s)
			col = col.lerp(base.lightened(0.20), f * 0.25)
			img.set_pixel(xx, yy, col)
	for i in range(1700):
		var x := randi() % sz
		var y := randi() % sz
		img.set_pixel(x, y, flecks[randi() % flecks.size()])
	var tex := ImageTexture.create_from_image(img)
	return _wrap_ground(tex, 1.0)

func _season_ground(s: String) -> ShaderMaterial:
	if ground_mats.has(s):
		return ground_mats[s]
	var m: ShaderMaterial
	match s:
		"Зима":
			m = _make_snow_ground_material()
		"Осень":
			# увядающая трава (зеленовато-оливковая основа: тёплый свет доводит её
			# до золотистой, а не оранжевой) + опавшие листья крапинками
			m = _field_mat(Color8(0x5c, 0x72, 0x4c),
				[AUTUMN[1], AUTUMN[3], Color8(0x8a, 0x6a, 0x30), Color8(0x6f, 0x7e, 0x44), Color8(0x86, 0x88, 0x50)])
		"Весна":
			m = _field_mat(Color8(0x6f, 0xc0, 0x52),
				[Color8(0x9f, 0xe0, 0x6a), FLOWER_COLS[1], FLOWER_COLS[4], FLOWER_COLS[7], Color8(0x55, 0xa8, 0x40)])
		_:
			m = grass_mat
	ground_mats[s] = m
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

# ---- Зимний декор: деревья «в снегу», сугробы ----
func _snowm() -> StandardMaterial3D:
	if snow_white_mat == null:
		snow_white_mat = StandardMaterial3D.new()
		snow_white_mat.albedo_color = Color(0.95, 0.97, 1.0)
		snow_white_mat.roughness = 0.85
	return snow_white_mat

func _make_snowy_round_tree(green: Color) -> Node3D:
	var frost := green.lerp(Color(0.86, 0.90, 0.86), 0.45)   # подмороженная листва
	var r := Node3D.new()
	r.add_child(_mi(cyl_mesh, get_mat(TRUNK_COL), Vector3(0, 7.0, 0), Vector3(2.4, 14, 2.4), true))
	r.add_child(_mi(sphere_mesh, get_mat(frost), Vector3(0, 18.0, 0), Vector3(11.5, 12.0, 11.5), true))
	r.add_child(_mi(sphere_mesh, get_mat(frost.lightened(0.10)), Vector3(3.5, 22.0, 2.0), Vector3(7.2, 7.2, 7.2), true))
	r.add_child(_mi(sphere_mesh, get_mat(frost.darkened(0.06)), Vector3(-3.8, 20.0, -2.2), Vector3(6.6, 6.6, 6.6), true))
	# снежные шапки сверху (приплюснутые белые сферы)
	r.add_child(_mi(sphere_mesh, _snowm(), Vector3(0, 22.5, 0), Vector3(10.5, 4.2, 10.5), true))
	r.add_child(_mi(sphere_mesh, _snowm(), Vector3(3.5, 25.0, 2.0), Vector3(6.2, 3.0, 6.2), true))
	r.add_child(_mi(sphere_mesh, _snowm(), Vector3(-3.8, 23.0, -2.2), Vector3(5.6, 2.8, 5.6), true))
	return r

func _make_snowy_pine(green: Color) -> Node3D:
	var frost := green.lerp(Color(0.80, 0.86, 0.84), 0.40)
	var r := Node3D.new()
	r.add_child(_mi(cyl_mesh, get_mat(TRUNK_COL), Vector3(0, 5.0, 0), Vector3(2.0, 10, 2.0), true))
	r.add_child(_mi(cone_mesh, get_mat(frost), Vector3(0, 15, 0), Vector3(11, 13, 11), true))
	r.add_child(_mi(cone_mesh, _snowm(), Vector3(0, 17.5, 0), Vector3(11.4, 5.5, 11.4), true))
	r.add_child(_mi(cone_mesh, get_mat(frost.lightened(0.05)), Vector3(0, 22, 0), Vector3(8, 11, 8), true))
	r.add_child(_mi(cone_mesh, _snowm(), Vector3(0, 24.5, 0), Vector3(8.3, 4.5, 8.3), true))
	r.add_child(_mi(cone_mesh, get_mat(frost.lightened(0.10)), Vector3(0, 28, 0), Vector3(5.4, 8, 5.4), true))
	r.add_child(_mi(cone_mesh, _snowm(), Vector3(0, 31.0, 0), Vector3(5.8, 4.0, 5.8), true))
	return r

func _make_snow_mound() -> Node3D:
	# небольшой сугроб — кучка приплюснутых белых сфер
	var r := Node3D.new()
	var offs := [Vector3(0, 1.6, 0), Vector3(-2.6, 1.2, 0.6), Vector3(2.4, 1.2, -0.5), Vector3(0.3, 1.4, 2.2)]
	var scl := [Vector3(4.6, 2.6, 4.6), Vector3(3.0, 1.8, 3.0), Vector3(3.2, 1.9, 3.2), Vector3(2.6, 1.6, 2.6)]
	for i in range(offs.size()):
		r.add_child(_mi(sphere_mesh, _snowm(), offs[i], scl[i], true))
	return r

func _make_blossom_tree(green: Color, blossom: Color) -> Node3D:
	# весеннее цветущее дерево: зелёная крона + гроздья цветения
	var r := Node3D.new()
	r.add_child(_mi(cyl_mesh, get_mat(TRUNK_COL), Vector3(0, 7.0, 0), Vector3(2.4, 14, 2.4), true))
	r.add_child(_mi(sphere_mesh, get_mat(green), Vector3(0, 18.0, 0), Vector3(11.5, 12.0, 11.5), true))
	r.add_child(_mi(sphere_mesh, get_mat(green.lightened(0.10)), Vector3(3.5, 22.0, 2.0), Vector3(7.2, 7.2, 7.2), true))
	r.add_child(_mi(sphere_mesh, get_mat(green.darkened(0.08)), Vector3(-3.8, 20.0, -2.2), Vector3(6.6, 6.6, 6.6), true))
	var bm := get_mat(blossom, 0.6)
	var pos := [Vector3(0, 24.5, 0), Vector3(5.5, 21.0, 2.5), Vector3(-5.0, 22.0, -2.0), Vector3(2.0, 19.5, 5.5), Vector3(-3.0, 25.0, 1.5)]
	for p in pos:
		r.add_child(_mi(sphere_mesh, bm, p, Vector3(3.4, 3.0, 3.4), true))
	return r

func _hold_protos(arrs: Array) -> void:
	# держим прототипы как скрытых детей сцены (не рендерятся и не «утекают»)
	if proto_holder == null:
		proto_holder = Node3D.new()
		proto_holder.visible = false
		add_child(proto_holder)
	for arr in arrs:
		for p in arr:
			if p.get_parent() == null:
				proto_holder.add_child(p)

func _build_decor_library() -> void:
	# общий меш + материал травы (цвет задаётся per-instance через MultiMesh)
	tuft_mm_mesh = _make_tuft_mesh(Color.WHITE)
	tuft_mm_mat = StandardMaterial3D.new()
	tuft_mm_mat.albedo_color = Color.WHITE
	tuft_mm_mat.vertex_color_use_as_albedo = true
	tuft_mm_mat.roughness = 0.9
	tuft_mm_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Лето
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
	# Зима
	lib_snow_tree.append(_make_snowy_round_tree(GREENS[3]))
	lib_snow_tree.append(_make_snowy_round_tree(GREENS[1]))
	lib_snow_tree.append(_make_snowy_pine(GREENS[3]))
	lib_snow_tree.append(_make_snowy_pine(GREENS[0]))
	lib_snow_mound.append(_make_snow_mound())
	# Осень
	lib_autumn_tree.append(_make_round_tree(AUTUMN[0]))
	lib_autumn_tree.append(_make_round_tree(AUTUMN[1]))
	lib_autumn_tree.append(_make_round_tree(AUTUMN[3]))
	lib_autumn_tree.append(_make_pine(GREENS[3].lerp(AUTUMN[4], 0.35)))
	lib_autumn_bush.append(_make_bush(AUTUMN[1]))
	lib_autumn_bush.append(_make_bush(AUTUMN[4]))
	# Весна
	lib_spring_tree.append(_make_round_tree(SPRING_GREEN[0]))
	lib_spring_tree.append(_make_round_tree(SPRING_GREEN[2]))
	lib_spring_tree.append(_make_blossom_tree(SPRING_GREEN[2], BLOSSOM[0]))
	lib_spring_tree.append(_make_blossom_tree(SPRING_GREEN[1], BLOSSOM[2]))
	lib_spring_tree.append(_make_pine(GREENS[0]))
	_hold_protos([lib_flower, lib_bush, lib_tree, lib_rock,
		lib_snow_tree, lib_snow_mound, lib_autumn_tree, lib_autumn_bush, lib_spring_tree])

func _build_decor(t: Tile) -> void:
	# генерируем раскладку (позиции травы и декора) ОДИН раз; декор конкретного
	# сезона строится в отдельном контейнере (другие сезоны — лениво)
	var HW := BAND * 0.5
	# трава
	var gp := 0
	var gg := 0
	while gp < 1200 and gg < 10000:
		gg += 1
		var a := randf() * TAU
		var rad := sqrt(randf()) * A * 1.03
		var x := cos(a) * rad
		var y := sin(a) * rad
		if _dist_to_roads(x, y) - HW > 1.0:
			var tsc := 0.35 + randf() * 0.5
			var tb := Basis(Vector3.UP, randf() * TAU).scaled(Vector3.ONE * tsc)
			t.grass_x.append(Transform3D(tb, Vector3(x, 0, y)))
			gp += 1
	# цветочки
	var placed := 0
	var guard := 0
	while placed < 28 and guard < 1200:
		guard += 1
		var a := randf() * TAU
		var rad := sqrt(randf()) * A * 0.98
		var x := cos(a) * rad
		var y := sin(a) * rad
		if _dist_to_roads(x, y) - HW > 2.0:
			t.items.append({"type": "flower", "x": x, "y": y, "sc": 0.425 + randf() * 0.4, "rot": randf() * TAU})
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
			t.items.append({"type": "rock", "x": x, "y": y, "sc": 0.65 + randf() * 0.7, "rot": randf() * TAU})
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
		t.items.append({"type": type, "x": x, "y": y, "sc": sc, "rot": randf() * TAU})
		placed += 1
	# дополнительный проход деревьев (удвоение) — подальше от дороги
	placed = 0
	guard = 0
	while placed < 8 and guard < 500:
		guard += 1
		var a := randf() * TAU
		var rad := sqrt(randf()) * A * 0.92
		var x := cos(a) * rad
		var y := sin(a) * rad
		if _dist_to_roads(x, y) - HW > 8.0:
			t.items.append({"type": "tree", "x": x, "y": y, "sc": 0.8 + randf() * 0.5, "rot": randf() * TAU})
			placed += 1
	_build_season_decor(t, season)   # стартовый сезон (Лето)

func _grass_palette(s: String) -> Array:
	match s:
		"Осень": return AUTUMN_GRASS
		"Весна": return SPRING_GREEN
		_: return GREENS

func _build_season_decor(t: Tile, s: String) -> void:
	var cont := Node3D.new()
	t.pivot.add_child(cont)
	t.deco[s] = cont
	# трава (кроме зимы) — общий меш, цвет по сезону
	if s != "Зима" and t.grass_x.size() > 0:
		var pal := _grass_palette(s)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = tuft_mm_mesh
		mm.instance_count = t.grass_x.size()
		for i in range(t.grass_x.size()):
			mm.set_instance_transform(i, t.grass_x[i])
			mm.set_instance_color(i, pal[randi() % pal.size()])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = tuft_mm_mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		cont.add_child(mmi)
	# декор по сохранённой раскладке
	for it in t.items:
		var proto := _season_proto(s, it.type)
		if proto == null:
			continue
		var n := proto.duplicate() as Node3D
		n.position = Vector3(it.x, 0.0, it.y)
		n.scale = Vector3.ONE * float(it.sc)
		n.rotation.y = it.rot
		cont.add_child(n)

func _season_proto(s: String, type: String) -> Node3D:
	match s:
		"Зима":
			match type:
				"tree": return lib_snow_tree[randi() % lib_snow_tree.size()]
				"bush", "rock": return lib_snow_mound[0]
				_: return null   # цветы под снегом не показываем
		"Осень":
			match type:
				"tree": return lib_autumn_tree[randi() % lib_autumn_tree.size()]
				"bush": return lib_autumn_bush[randi() % lib_autumn_bush.size()]
				"rock": return lib_rock[randi() % lib_rock.size()]
				_: return lib_flower[randi() % lib_flower.size()] if randf() < 0.25 else null
		"Весна":
			match type:
				"tree": return lib_spring_tree[randi() % lib_spring_tree.size()]
				"bush": return lib_bush[randi() % lib_bush.size()]
				"rock": return lib_rock[randi() % lib_rock.size()]
				_: return lib_flower[randi() % lib_flower.size()]
		_:  # Лето
			match type:
				"tree": return lib_tree[randi() % lib_tree.size()]
				"bush": return lib_bush[randi() % lib_bush.size()]
				"rock": return lib_rock[randi() % lib_rock.size()]
				_: return lib_flower[randi() % lib_flower.size()]
	return null

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
		spot.light_color = look.get("hl_color", Color(1.0, 0.95, 0.78))
		spot.light_energy = look.get("hl_energy", 38.0)
		spot.spot_range = look.get("hl_range", 420.0)
		spot.spot_angle = look.get("hl_angle", 30.0)
		spot.spot_angle_attenuation = 0.7
		spot.spot_attenuation = 0.6
		spot.shadow_enabled = false
		spot.transform = Transform3D(Basis(lx, ly, lz), Vector3(length * 0.5, hl_y, s * width * 0.30))
		root.add_child(spot)
		c.lights.append(spot)
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
# Художественный пост-эффект (полноэкранный canvas-шейдер)
# ======================================================================
const _FX_SHADER := """
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform int u_style = 0;
uniform float u_canny_low = 0.22;    // нижний порог (слабые края — тянутся только к сильным)
uniform float u_canny_high = 0.52;   // верхний порог (сильные края)
uniform float u_canny_line = 0.85;   // насыщенность линии (0..1)
uniform float u_canny_paper = 0.015; // зерно бумаги (0 — чистый фон)
uniform float u_canny_mult = 0.0;    // 0 — линии на бумаге, 1 — линии ×цветной рендер (multiply)
uniform float u_canny_toon = 0.0;    // 1 — базовый цвет проходит через тун-градиент перед наложением
uniform float u_canny_thick = 0.0;   // радиус (px) жирного тун-контура поверх тонких линий (0 — выкл)

float luma(vec3 c){ return dot(c, vec3(0.299, 0.587, 0.114)); }
float hash(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float vnoise(vec2 p){
	vec2 i = floor(p), f = fract(p);
	float a = hash(i), b = hash(i + vec2(1.0, 0.0)), c = hash(i + vec2(0.0, 1.0)), d = hash(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
vec3 samp(vec2 uv){ return texture(screen_tex, uv).rgb; }
vec3 blur9(vec2 uv, vec2 px, float r){
	vec3 s = samp(uv) * 4.0;
	s += samp(uv + vec2(px.x, 0.0) * r) + samp(uv - vec2(px.x, 0.0) * r);
	s += samp(uv + vec2(0.0, px.y) * r) + samp(uv - vec2(0.0, px.y) * r);
	s += samp(uv + px * r) + samp(uv - px * r);
	s += samp(uv + vec2(px.x, -px.y) * r) + samp(uv - vec2(px.x, -px.y) * r);
	return s / 12.0;
}
float edge_sobel(vec2 uv, vec2 px){
	float tl = luma(samp(uv + px * vec2(-1.0, -1.0)));
	float t  = luma(samp(uv + px * vec2( 0.0, -1.0)));
	float tr = luma(samp(uv + px * vec2( 1.0, -1.0)));
	float l  = luma(samp(uv + px * vec2(-1.0,  0.0)));
	float r  = luma(samp(uv + px * vec2( 1.0,  0.0)));
	float bl = luma(samp(uv + px * vec2(-1.0,  1.0)));
	float b  = luma(samp(uv + px * vec2( 0.0,  1.0)));
	float br = luma(samp(uv + px * vec2( 1.0,  1.0)));
	float gx = -tl - 2.0 * l - bl + tr + 2.0 * r + br;
	float gy = -tl - 2.0 * t - tr + bl + 2.0 * b + br;
	return sqrt(gx * gx + gy * gy);
}
// сглаженная яркость (гаусс 3x3, радиус R) — подавление шума перед детекцией Canny
uniform float u_canny_blur = 1.7;
float luma_blur(vec2 uv, vec2 px){
	vec2 r = px * u_canny_blur;
	float s = luma(samp(uv)) * 4.0;
	s += (luma(samp(uv + vec2(r.x, 0.0))) + luma(samp(uv - vec2(r.x, 0.0)))) * 2.0;
	s += (luma(samp(uv + vec2(0.0, r.y))) + luma(samp(uv - vec2(0.0, r.y)))) * 2.0;
	s += luma(samp(uv + r)) + luma(samp(uv - r));
	s += luma(samp(uv + vec2(r.x, -r.y))) + luma(samp(uv - vec2(r.x, -r.y)));
	return s / 16.0;
}
// градиент Собеля по сглаженной яркости (центр — качественно)
vec2 sobel_grad(vec2 uv, vec2 px){
	float tl = luma_blur(uv + px * vec2(-1.0, -1.0), px);
	float t  = luma_blur(uv + px * vec2( 0.0, -1.0), px);
	float tr = luma_blur(uv + px * vec2( 1.0, -1.0), px);
	float l  = luma_blur(uv + px * vec2(-1.0,  0.0), px);
	float r  = luma_blur(uv + px * vec2( 1.0,  0.0), px);
	float bl = luma_blur(uv + px * vec2(-1.0,  1.0), px);
	float b  = luma_blur(uv + px * vec2( 0.0,  1.0), px);
	float br = luma_blur(uv + px * vec2( 1.0,  1.0), px);
	float gx = -tl - 2.0 * l - bl + tr + 2.0 * r + br;
	float gy = -tl - 2.0 * t - tr + bl + 2.0 * b + br;
	return vec2(gx, gy);
}
float gmag(vec2 uv, vec2 px){ return length(sobel_grad(uv, px)); }
// магнитуда по сглаженной яркости — для проверки соседей (NMS/гистерезис), тот же денойз
float gmag_fast(vec2 uv, vec2 px){ return length(sobel_grad(uv, px)); }

// жирный контур: Собель с широким шагом w (px) — отклик шире → толстая линия силуэта
float thick_edge(vec2 uv, vec2 px, float w){
	vec2 o = px * w;
	float tl = luma(samp(uv + vec2(-o.x, -o.y)));
	float t  = luma(samp(uv + vec2( 0.0, -o.y)));
	float tr = luma(samp(uv + vec2( o.x, -o.y)));
	float l  = luma(samp(uv + vec2(-o.x,  0.0)));
	float r  = luma(samp(uv + vec2( o.x,  0.0)));
	float bl = luma(samp(uv + vec2(-o.x,  o.y)));
	float b  = luma(samp(uv + vec2( 0.0,  o.y)));
	float br = luma(samp(uv + vec2( o.x,  o.y)));
	float gx = -tl - 2.0 * l - bl + tr + 2.0 * r + br;
	float gy = -tl - 2.0 * t - tr + bl + 2.0 * b + br;
	return sqrt(gx * gx + gy * gy);
}

// Canny с антиалиасингом: пороги через smoothstep дают дробное покрытие на краю линии
float canny_ink(vec2 uv, vec2 px){
	vec2 g = sobel_grad(uv, px);
	float mag = length(g);
	vec2 dir = mag > 1e-4 ? g / mag : vec2(0.0, 0.0);
	float ma = gmag_fast(uv + dir * px, px);
	float mb = gmag_fast(uv - dir * px, px);
	float nms = (mag >= ma && mag >= mb) ? mag : 0.0;
	float n_r = gmag_fast(uv + vec2(px.x, 0.0), px);
	float n_l = gmag_fast(uv - vec2(px.x, 0.0), px);
	float n_u = gmag_fast(uv + vec2(0.0, px.y), px);
	float n_d = gmag_fast(uv - vec2(0.0, px.y), px);
	float hl = u_canny_high * 0.6;
	float ll = u_canny_low * 0.6;
	float strong = smoothstep(hl, u_canny_high, nms);
	float weak = smoothstep(ll, u_canny_low, nms);
	float near_strong = max(max(smoothstep(hl, u_canny_high, n_r), smoothstep(hl, u_canny_high, n_l)),
	                        max(smoothstep(hl, u_canny_high, n_u), smoothstep(hl, u_canny_high, n_d)));
	// мягкая связность: одиночная точка без соседей-краёв отбрасывается
	float conn = smoothstep(ll, u_canny_low, n_r) + smoothstep(ll, u_canny_low, n_l)
	           + smoothstep(ll, u_canny_low, n_u) + smoothstep(ll, u_canny_low, n_d);
	float keep = clamp(conn, 0.0, 1.0);
	return clamp(max(strong, weak * near_strong) * keep, 0.0, 1.0);
}

// тун-градиент (ч/б): мягкие ступени яркости — плавный переход между ступенями
float toon_lum(vec3 c){
	float l = luma(c);
	float L = l * 0.75 + 0.22;                                    // приподнять тени — не проваливаются в чёрный
	float bands = 4.0;
	float q = floor(L * bands) / bands;
	float f = fract(L * bands);
	return clamp(q + (1.0 / bands) * smoothstep(0.35, 0.65, f), 0.0, 1.0);
}

void fragment(){
	vec2 uv = SCREEN_UV;
	vec2 px = SCREEN_PIXEL_SIZE;
	vec2 res = 1.0 / px;
	vec3 col = samp(uv);

	if (u_style == 1){
		// ТУН — постеризация + чёрный контур
		vec3 c = col;
		float l = luma(c);
		c = mix(vec3(l), c, 1.25);                 // чуть насыщеннее
		c = floor(c * 5.0 + 0.5) / 5.0;            // ступени цвета
		float e = edge_sobel(uv, px);
		float ink = smoothstep(0.28, 0.55, e);
		c = mix(c, vec3(0.05, 0.05, 0.07), ink);
		col = c;
	} else if (u_style == 2){
		// АКВАРЕЛЬ — растёкшийся мягкий цвет, пигмент по краям, бумага
		vec2 wob = (vec2(vnoise(uv * res * 0.012), vnoise(uv * res * 0.012 + 19.7)) - 0.5) * px * 10.0;
		vec3 c = blur9(uv + wob, px, 1.6);
		c = mix(c, floor(c * 6.0 + 0.5) / 6.0, 0.5);
		float e = edge_sobel(uv, px);
		c *= 1.0 - 0.45 * smoothstep(0.12, 0.5, e);
		float l = luma(c);
		c = mix(vec3(l), c, 0.85);                 // лёгкая десатурация
		c = mix(c, vec3(0.98, 0.96, 0.92), 0.12);  // промыв к бумаге
		float paper2 = vnoise(uv * res * 0.04);    // только мягкая крупная вариация, без зерна
		c *= 0.975 + 0.025 * paper2;
		col = clamp(c, 0.0, 1.0);
	} else if (u_style == 3){
		// ГУАШЬ — плотные плоские матовые мазки
		vec3 c = blur9(uv, px, 1.2);
		c = pow(clamp(c, 0.0, 1.0), vec3(0.82));   // приподнять тени (краска кроет, нет провалов в чёрный)
		c = floor(c * 4.0 + 0.5) / 4.0;            // плотная постеризация
		c = max(c, vec3(0.14));                    // нет чистого чёрного
		c = mix(c, vec3(0.5), 0.06);               // матовость
		c = mix(vec3(luma(c)), c, 1.12);           // чуть насыщеннее
		float e = edge_sobel(uv, px);
		c *= 1.0 - 0.20 * smoothstep(0.2, 0.55, e);
		float canvas = vnoise(uv * res * 0.05);    // мягкая крупная вариация краски, без зернистого шума
		c *= 0.97 + 0.03 * canvas;
		col = clamp(c, 0.0, 1.0);
	} else if (u_style == 7){
		// ТУН ГРАДИЕНТ (ч/б) — мягкие ступени яркости + мягкий контур
		float t = toon_lum(col);
		vec3 c = vec3(t);
		float e = edge_sobel(uv, px);
		c = mix(c, c * 0.18, smoothstep(0.3, 0.6, e));
		col = clamp(c, 0.0, 1.0);
	} else if (u_style >= 4){
		// КАРАНДАШ / CANNY (антиалиас) — контур; mult → ×цвет, toon → ч/б тун multiply на цвет
		float ink = canny_ink(uv, px) * u_canny_line;
		if (u_canny_thick > 0.01){
			// жирный тун-контур силуэтов поверх тонких линий
			float te = thick_edge(uv, px, u_canny_thick);
			float thick = smoothstep(u_canny_high * 0.8, u_canny_high * 1.5, te);
			ink = max(ink, thick);
		}
		// ч/б тун как multiply-слой: множитель вокруг 1.0 (ступени затемняют/осветляют, без общего провала)
		vec3 base = (u_canny_toon > 0.5) ? clamp(col * (0.65 + 0.7 * toon_lum(col)), 0.0, 1.0) : col;
		float paper = 1.0 - u_canny_paper + u_canny_paper * vnoise(uv * res * 0.04);
		vec3 line_col = vec3(paper) - ink * vec3(0.86, 0.86, 0.84);   // линии на бумаге
		vec3 mult_col = base * (1.0 - ink);                          // линии × рендер (multiply)
		col = clamp(mix(line_col, mult_col, u_canny_mult), 0.0, 1.0);
	}
	COLOR = vec4(col, 1.0);
}
"""

func _build_fx() -> void:
	fx_layer = CanvasLayer.new()
	fx_layer.layer = 0   # поверх 3D, но под UI (ui.layer = 1)
	add_child(fx_layer)
	var sh := Shader.new()
	sh.code = _FX_SHADER
	fx_mat = ShaderMaterial.new()
	fx_mat.shader = sh
	fx_mat.set_shader_parameter("u_style", 0)
	fx_rect = ColorRect.new()
	fx_rect.material = fx_mat
	fx_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	fx_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fx_rect.visible = false
	fx_layer.add_child(fx_rect)

func set_style(idx: int) -> void:
	current_style = clampi(idx, 0, STYLE_NAMES.size() - 1)
	if fx_mat:
		fx_mat.set_shader_parameter("u_style", current_style)
		if CANNY_CFG.has(current_style):
			var cfg: Dictionary = CANNY_CFG[current_style]
			fx_mat.set_shader_parameter("u_canny_low", cfg["low"])
			fx_mat.set_shader_parameter("u_canny_high", cfg["high"])
			fx_mat.set_shader_parameter("u_canny_blur", cfg["blur"])
			fx_mat.set_shader_parameter("u_canny_line", cfg["line"])
			fx_mat.set_shader_parameter("u_canny_paper", cfg["paper"])
			fx_mat.set_shader_parameter("u_canny_mult", cfg.get("mult", 0.0))
			fx_mat.set_shader_parameter("u_canny_toon", cfg.get("toon", 0.0))
			fx_mat.set_shader_parameter("u_canny_thick", cfg.get("thick", 0.0))
	if fx_rect:
		fx_rect.visible = current_style != 0
	_update_style_fx_buttons()
	_flash("Стиль: " + STYLE_NAMES[current_style])

func _update_style_fx_buttons() -> void:
	for i in style_fx_buttons:
		style_fx_buttons[i].modulate = Color(1, 0.85, 0.35) if i == current_style else Color(1, 1, 1)

# ======================================================================
# Окружение / камера / маркер
# ======================================================================
var _NIGHT_SKY_SHADER := """
shader_type sky;

uniform vec3 u_sky_top = vec3(0.003, 0.005, 0.016);
uniform vec3 u_sky_horizon = vec3(0.018, 0.026, 0.058);
uniform float u_star = 1.0;
uniform vec3 u_sun_dir = vec3(0.4, 0.6, 0.5);
uniform vec3 u_sun_color = vec3(1.0, 0.85, 0.6);
uniform float u_sun = 0.0;

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

float star_layer(vec3 d, float scale, float thr) {
	vec3 p = d * scale;
	vec3 cell = floor(p);
	float h = hash(cell);
	if (h <= thr) return 0.0;
	vec3 fp = fract(p) - 0.5;
	float core = smoothstep(0.45, 0.0, length(fp));
	float bright = (h - thr) / (1.0 - thr);
	float tw = 0.5 + 0.5 * sin(TIME * 2.5 + h * 120.0);
	return core * bright * (0.4 + 0.6 * tw);
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float up = clamp(d.y, 0.0, 1.0);
	vec3 base = mix(u_sky_horizon, u_sky_top, up);
	float star = 0.0;
	if (u_star > 0.001 && d.y > 0.01) {
		star += star_layer(d, 200.0, 0.983);
		star += star_layer(d, 340.0, 0.989) * 0.8;
		star *= smoothstep(0.0, 0.10, d.y) * u_star;
	}
	vec3 sc = mix(vec3(0.8, 0.86, 1.0), vec3(1.0, 0.94, 0.78), hash(floor(d * 97.0)));
	COLOR = base + sc * star * 3.0;
	// солнце: яркий тёплый диск + ореол + лёгкое потепление неба у солнца
	if (u_sun > 0.001) {
		float c = dot(d, normalize(u_sun_dir));
		float disk = smoothstep(0.9965, 0.9990, c);
		float halo = pow(max(c, 0.0), 48.0) * 0.6;
		float warm = pow(max(c, 0.0), 6.0) * 0.18;
		COLOR += u_sun_color * (disk * 8.0 + halo + warm) * u_sun;
	}
}
"""

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_shader := Shader.new()
	sky_shader.code = _NIGHT_SKY_SHADER
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = sky_shader
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	# конкретные значения света/неба/свечения берутся из пресета (_apply_look)
	# объёмный туман выключен: при дальней камере он затягивал всё поле в дымку
	env.volumetric_fog_enabled = false
	we.environment = env
	add_child(we)

	# направленный свет (луна/солнце — цвет и яркость из пресета)
	moon = DirectionalLight3D.new()
	moon.rotation = Vector3(deg_to_rad(-15.0), deg_to_rad(35.0), 0.0)  # ниже к горизонту — солнце видно, тени длиннее
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 3000.0
	moon.directional_shadow_blend_splits = true
	add_child(moon)

	# земля (трава ↔ снег по сезону)
	ground = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = _ground_plane_size()
	ground.mesh = pm
	grass_mat = _make_grass_material()
	ground.material_override = grass_mat
	ground.position = Vector3(FIELD_W * 0.5, -0.5, FIELD_H * 0.5)
	add_child(ground)

	_apply_look()   # применить текущий пресет к окружению

# шейдер частиц погоды: мягко гасит прозрачность к краям поля по ЭЛЛИПТИЧЕСКОЙ
# маске (нормировка на полуразмер поля) — на виде сверху дождь/снег круглo
# растворяются вокруг поля, без резкого квадрата
const WEATHER_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, blend_mix;
uniform vec4 base_color : source_color;
uniform vec3 emit : source_color;
uniform float emit_energy = 1.0;
uniform vec2 center;
uniform vec2 half_ext;
uniform float inner = 0.90;
uniform float outer = 1.33;
varying vec2 wxz;
void vertex() {
	wxz = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xz;
}
void fragment() {
	vec2 n = (wxz - center) / half_ext;
	float d = length(n);               // эллиптические изолинии — без углов/квадрата
	float fade = 1.0 - smoothstep(inner, outer, d);
	ALBEDO = base_color.rgb;
	EMISSION = emit * emit_energy;
	ALPHA = base_color.a * fade;
}
"""

func _weather_mat(base: Color, emit: Color, emit_energy: float, cx: float, cz: float, hx: float, hz: float) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = WEATHER_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("base_color", base)
	m.set_shader_parameter("emit", Vector3(emit.r, emit.g, emit.b))
	m.set_shader_parameter("emit_energy", emit_energy)
	m.set_shader_parameter("center", Vector2(cx, cz))
	m.set_shader_parameter("half_ext", Vector2(hx, hz))
	return m

func _build_weather() -> void:
	var cx := FIELD_W * 0.5
	var cz := FIELD_H * 0.5
	var ext_x := FIELD_W * 0.5 + 250.0
	var ext_z := FIELD_H * 0.5 + 250.0
	var top := 700.0        # высота спавна дождя
	var snow_h := 520.0     # снег рождается во всём столбе от земли до этой высоты
	var snow_mid := snow_h * 0.5

	# --- ДОЖДЬ: вытянутые косые струи, быстро падают на землю ---
	rain_ps = GPUParticles3D.new()
	var rdrop := BoxMesh.new()
	rdrop.size = Vector3(0.22, 12.0, 0.22)   # вдвое тоньше/короче
	rdrop.material = _weather_mat(Color(0.82, 0.88, 1.0, 0.55), Color(0.7, 0.8, 1.0), 0.6, cx, cz, FIELD_W * 0.5, FIELD_H * 0.5)
	rain_ps.draw_pass_1 = rdrop
	var rp := ParticleProcessMaterial.new()
	rp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	rp.emission_box_extents = Vector3(ext_x, 1.0, ext_z)
	rp.direction = Vector3(0.16, -1.0, 0.06)
	rp.spread = 1.5
	rp.gravity = Vector3(40.0, -1500.0, 15.0)
	rp.initial_velocity_min = 950.0
	rp.initial_velocity_max = 1150.0
	rp.scale_min = 0.5
	rp.scale_max = 0.85
	rain_ps.process_material = rp
	rain_ps.amount = 16800       # ещё вдвое гуще
	rain_ps.lifetime = 0.7
	rain_ps.preprocess = 0.7
	rain_ps.fixed_fps = 0
	rain_ps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rain_ps.position = Vector3(cx, top, cz)
	# AABB видимости охватывает весь объём падения (иначе частицы у земли отсекаются)
	rain_ps.visibility_aabb = AABB(Vector3(-ext_x, -top - 100.0, -ext_z), Vector3(2.0 * ext_x, top + 200.0, 2.0 * ext_z))
	rain_ps.visible = false
	rain_ps.emitting = false
	add_child(rain_ps)

	# --- СНЕГ: мелкие мягкие хлопья, заметно падают и слегка кружат ---
	snow_ps = GPUParticles3D.new()
	var flake := SphereMesh.new()
	flake.radius = 0.55     # вдвое мельче
	flake.height = 1.1
	flake.radial_segments = 6
	flake.rings = 4
	flake.material = _weather_mat(Color(1.0, 1.0, 1.0, 0.95), Color(0.95, 0.97, 1.0), 0.5, cx, cz, FIELD_W * 0.5, FIELD_H * 0.5)
	snow_ps.draw_pass_1 = flake
	var sp := ParticleProcessMaterial.new()
	sp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	# хлопья рождаются равномерно по всей высоте столба — поэтому снег виден
	# одинаково и у земли, и наверху, а не тонким слоем у точки спавна
	sp.emission_box_extents = Vector3(ext_x, snow_mid, ext_z)
	sp.direction = Vector3(0.05, -1.0, 0.03)
	sp.spread = 8.0
	# заметная скорость + умеренное ускорение — снег явно стремится вниз,
	# но всё ещё достаточно равномерен по высоте столба
	sp.gravity = Vector3(0.0, -30.0, 0.0)
	sp.initial_velocity_min = 180.0
	sp.initial_velocity_max = 250.0
	sp.scale_min = 0.5
	sp.scale_max = 0.95
	# слабая турбулентность — только лёгкое покачивание, не мешает падению
	sp.turbulence_enabled = true
	sp.turbulence_noise_strength = 9.0
	sp.turbulence_noise_scale = 1.2
	snow_ps.process_material = sp
	snow_ps.amount = 26000
	snow_ps.lifetime = 6.0
	snow_ps.preprocess = 6.0
	snow_ps.fixed_fps = 0
	snow_ps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	snow_ps.position = Vector3(cx, snow_mid, cz)
	# AABB от заметно ниже земли до верха столба — чтобы ничего не отсекалось
	snow_ps.visibility_aabb = AABB(Vector3(-ext_x, -snow_mid - 400.0, -ext_z), Vector3(2.0 * ext_x, snow_h + 600.0, 2.0 * ext_z))
	snow_ps.visible = false
	snow_ps.emitting = false
	add_child(snow_ps)

func set_weather(mode: int) -> void:
	weather = (mode % WEATHER_NAMES.size() + WEATHER_NAMES.size()) % WEATHER_NAMES.size()
	if rain_ps:
		rain_ps.visible = weather == 1
		rain_ps.emitting = weather == 1
	if snow_ps:
		snow_ps.visible = weather == 2
		snow_ps.emitting = weather == 2
	_update_weather_btn()

func _update_weather_btn() -> void:
	if weather_btn:
		weather_btn.text = "Погода: " + WEATHER_NAMES[weather]
		weather_btn.modulate = Color(0.6, 0.8, 1.0) if weather != 0 else Color(1, 1, 1)

func _v3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)

# применить текущий набор настроек look ко всей сцене
func _apply_look() -> void:
	if look.is_empty():
		return
	var g: Dictionary = SEASON_GRADE.get(season, SEASON_GRADE["Лето"])
	if env:
		env.ambient_light_color = look["ambient_color"] * g["amb"]
		env.ambient_light_energy = look["ambient_energy"]
		env.glow_intensity = look["glow_intensity"]
		env.glow_bloom = look["glow_bloom"]
		env.glow_hdr_threshold = look["glow_threshold"]
		# стиль рендера: тонмаппинг + экспозиция + цветокоррекция
		var tm := {
			"linear": Environment.TONE_MAPPER_LINEAR,
			"reinhard": Environment.TONE_MAPPER_REINHARDT,
			"filmic": Environment.TONE_MAPPER_FILMIC,
			"aces": Environment.TONE_MAPPER_ACES,
			"agx": Environment.TONE_MAPPER_AGX,
		}
		env.tonemap_mode = tm.get(look.get("tonemap", "filmic"), Environment.TONE_MAPPER_FILMIC)
		env.tonemap_exposure = look.get("exposure", 1.0)
		env.adjustment_enabled = true
		env.adjustment_brightness = look.get("brightness", 1.0) * g["bri"]
		env.adjustment_contrast = look.get("contrast", 1.0) * g["con"]
		env.adjustment_saturation = look.get("saturation", 1.0) * g["sat"]
	if moon:
		moon.light_color = look["moon_color"] * g["light"]
		moon.light_energy = look["moon_energy"]
	if sky_mat:
		sky_mat.set_shader_parameter("u_sky_top", _v3(look["sky_top"] * g["sky"]))
		# фон у горизонта (его и видно вокруг кромки поля) подгоняем максимально
		# близко к ЦВЕТУ ОСВЕЩЁННОЙ ЗЕМЛИ, чтобы переход поля в фон был незаметен
		var gb: Color = _ground_base_color(season)
		var amb_c: Color = look["ambient_color"] * g["amb"] * float(look["ambient_energy"])
		var dir_c: Color = look["moon_color"] * g["light"] * float(look["moon_energy"]) * 0.30
		var lit := Color(gb.r * (amb_c.r + dir_c.r), gb.g * (amb_c.g + dir_c.g), gb.b * (amb_c.b + dir_c.b))
		# фон чуть темнее и насыщеннее по цвету, чем сама земля
		lit.s = clampf(lit.s * 1.35, 0.0, 1.0)
		lit = lit.darkened(0.18)
		sky_mat.set_shader_parameter("u_sky_horizon", _v3(lit))
		sky_mat.set_shader_parameter("u_star", look["star"])
		sky_mat.set_shader_parameter("u_sun", look.get("sun", 0.0))
		if moon:
			# солнце в небе — там, откуда падает свет (ось +Z направленного света)
			sky_mat.set_shader_parameter("u_sun_dir", moon.global_transform.basis.z)
		sky_mat.set_shader_parameter("u_sun_color", _v3(look["moon_color"] * g["light"]))
	# фары существующих машинок
	for c in cars:
		for sp in c.lights:
			sp.light_energy = look["hl_energy"]
			sp.spot_range = look["hl_range"]
			sp.spot_angle = look["hl_angle"]
			sp.light_color = look["hl_color"]
	# подсветка кругов: сбросить старые материалы, чтобы пересоздались с новым свечением
	for k in colored_keys.keys():
		var p: PackedStringArray = k.split(":")
		tiles[int(p[0])].roads[int(p[1])].set_surface_override_material(0, null)
	colored_keys = {}
	for mk in mat_cache.keys():
		if str(mk).begins_with("roadtint|"):
			mat_cache.erase(mk)

func apply_preset(name: String) -> void:
	# пресет = время суток (свет/небо); сезон задаётся отдельно
	if PRESETS.has(name):
		look = PRESETS[name].duplicate(true)
		current_preset = name
		_apply_look()
		_update_style_buttons()
		_flash("Свет: " + name)

func set_season(name: String) -> void:
	if not SEASONS.has(name):
		return
	season = name
	# земля
	if ground:
		ground.material_override = _season_ground(name)
	# декор каждой плитки: показываем контейнер сезона (строим лениво при первом показе)
	for t in tiles:
		if not t.deco.has(name):
			_build_season_decor(t, name)
		for sk in t.deco:
			t.deco[sk].visible = (sk == name)
	# сезонная цветокоррекция света зависит от сезона → пересчёт
	_apply_look()
	# зимой включаем снегопад; при выходе из зимы убираем именно снег
	if name == "Зима":
		set_weather(2)
	elif weather == 2:
		set_weather(0)
	_update_season_buttons()
	_flash("Сезон: " + name)

func _update_season_buttons() -> void:
	for nm in season_buttons:
		season_buttons[nm].modulate = Color(1, 0.85, 0.35) if nm == season else Color(1, 1, 1)

func save_look() -> void:
	var c := ConfigFile.new()
	for k in look.keys():
		c.set_value("look", k, look[k])
	c.set_value("fx", "style", current_style)
	c.set_value("season", "name", season)
	var err := c.save(LOOK_PATH)
	_flash("Сохранено" if err == OK else "Ошибка сохранения")

func load_look() -> bool:
	var c := ConfigFile.new()
	if c.load(LOOK_PATH) != OK:
		return false
	for k in c.get_section_keys("look"):
		look[k] = c.get_value("look", k)
	current_preset = ""   # загружены свои настройки — ни один пресет не активен
	if c.has_section_key("season", "name"):
		set_season(c.get_value("season", "name", "Лето"))
	_apply_look()
	_update_style_buttons()
	if c.has_section_key("fx", "style"):
		set_style(int(c.get_value("fx", "style", 0)))
	_flash("Загружено")
	return true

func _flash(s: String) -> void:
	if flash_label == null:
		return
	flash_label.text = s
	flash_t = 1.8

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

	# кнопка бота (режим Кольца) — крутит плитки ради самых больших петель
	bot_btn = Button.new()
	bot_btn.text = "Бот: петли (B)"
	bot_btn.position = Vector2(16, 92)
	bot_btn.add_theme_font_size_override("font_size", 18)
	bot_btn.pressed.connect(toggle_bot)
	bot_btn.visible = false
	ui.add_child(bot_btn)

	# плашка-уведомление (пресет применён/сохранён) — вверху по центру
	flash_label = Label.new()
	flash_label.add_theme_font_size_override("font_size", 24)
	flash_label.add_theme_color_override("font_color", Color(1, 1, 1))
	flash_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	flash_label.add_theme_constant_override("outline_size", 5)
	flash_label.anchor_left = 0.0
	flash_label.anchor_right = 1.0
	flash_label.anchor_top = 0.06
	flash_label.anchor_bottom = 0.06
	flash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	flash_label.visible = false
	ui.add_child(flash_label)

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
	# не перехватываем мышь: клик должен дойти до _unhandled_input → _show_menu
	# (иначе после Погони/Бандита экран конца «съедает» клик и из него не выйти)
	over_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(over_panel)
	var odim := ColorRect.new()
	odim.color = Color(0, 0, 0, 0.55)
	odim.set_anchors_preset(Control.PRESET_FULL_RECT)
	odim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	over_panel.add_child(odim)
	over_title = Label.new()
	over_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	over_sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	over_sub.add_theme_font_size_override("font_size", 24)
	over_sub.anchor_left = 0.0
	over_sub.anchor_right = 1.0
	over_sub.anchor_top = 0.52
	over_sub.anchor_bottom = 0.52
	over_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	over_panel.add_child(over_sub)
	var hint := Label.new()
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	cam_hint.text = "Плитка: ЛКМ — повернуть (Shift — назад)   Камера: ПКМ/СКМ/колесо, Q/E/R/F/Z/X   Свет: 1 Ночь · 2 Сумерки · 3 День · F5 сохранить · F9 загрузить"
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

	_build_style_menu()

func _build_style_menu() -> void:
	style_panel = PanelContainer.new()
	style_panel.anchor_left = 1.0
	style_panel.anchor_right = 1.0
	style_panel.anchor_top = 0.0
	style_panel.anchor_bottom = 0.0
	style_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN  # растём влево от правого края
	style_panel.grow_vertical = Control.GROW_DIRECTION_END      # растём вниз
	style_panel.offset_left = -8
	style_panel.offset_right = -8
	style_panel.offset_top = 8
	style_panel.offset_bottom = 8
	style_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.55)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	style_panel.add_theme_stylebox_override("panel", sb)
	ui.add_child(style_panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	style_panel.add_child(vb)
	var title := Label.new()
	title.text = "Оформление"
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	# --- время суток (свет/небо) ---
	var ttl := Label.new()
	ttl.text = "Время суток"
	ttl.add_theme_font_size_override("font_size", 13)
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(ttl)
	for name in PRESETS.keys():
		var btn := Button.new()
		btn.text = name
		btn.custom_minimum_size = Vector2(165, 30)
		var nm: String = name
		btn.pressed.connect(func(): apply_preset(nm))
		vb.add_child(btn)
		style_buttons[name] = btn
	# --- сезон (поле + сезонный цвето-свет) ---
	vb.add_child(HSeparator.new())
	var stl := Label.new()
	stl.text = "Сезон"
	stl.add_theme_font_size_override("font_size", 13)
	stl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(stl)
	for sname in SEASONS:
		var sbtn := Button.new()
		sbtn.text = sname
		sbtn.custom_minimum_size = Vector2(165, 30)
		var snm: String = sname
		sbtn.pressed.connect(func(): set_season(snm))
		vb.add_child(sbtn)
		season_buttons[sname] = sbtn
	_update_season_buttons()
	vb.add_child(HSeparator.new())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	vb.add_child(row)
	var save_btn := Button.new()
	save_btn.text = "Сохранить"
	save_btn.custom_minimum_size = Vector2(80, 28)
	save_btn.pressed.connect(save_look)
	row.add_child(save_btn)
	var load_btn := Button.new()
	load_btn.text = "Загрузить"
	load_btn.custom_minimum_size = Vector2(80, 28)
	load_btn.pressed.connect(func(): load_look())
	row.add_child(load_btn)
	# --- погода ---
	vb.add_child(HSeparator.new())
	weather_btn = Button.new()
	weather_btn.custom_minimum_size = Vector2(165, 30)
	weather_btn.pressed.connect(func(): set_weather(weather + 1))
	vb.add_child(weather_btn)
	_update_weather_btn()
	# --- переключатель художественного стиля ---
	vb.add_child(HSeparator.new())
	var stitle := Label.new()
	stitle.text = "Стиль рисунка"
	stitle.add_theme_font_size_override("font_size", 14)
	stitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(stitle)
	for i in STYLE_NAMES.size():
		var sbtn := Button.new()
		sbtn.text = STYLE_NAMES[i]
		sbtn.custom_minimum_size = Vector2(165, 28)
		var idx: int = i
		sbtn.pressed.connect(func(): set_style(idx))
		vb.add_child(sbtn)
		style_fx_buttons[i] = sbtn
	_update_style_buttons()
	_update_style_fx_buttons()

func _update_style_buttons() -> void:
	for name in style_buttons:
		style_buttons[name].modulate = Color(1, 0.85, 0.35) if name == current_preset else Color(1, 1, 1)

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
	if bot_btn:
		bot_btn.visible = playing and loops
	if playing:
		if loops:
			hud_score.text = "Очки: " + str(score)
			hud_best.text = "Рекорд: " + str(best)
		else:
			hud_mode.text = "Догони бандита!" if mode == "chase" else "Уходи от полиции!"
			hud_time.text = "Время: %.1f c" % modeTime





