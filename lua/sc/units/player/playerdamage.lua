local mvec1 = Vector3()
PlayerDamage._UPPERS_COOLDOWN = tweak_data.upgrades.values.first_aid_kit.uppers_cooldown

function PlayerDamage:init(unit)
	self._lives_init = tweak_data.player.damage.LIVES_INIT
	self._lives_init = managers.modifiers:modify_value("PlayerDamage:GetMaximumLives", self._lives_init)
	self._unit = unit
	self._max_health_reduction = managers.player:upgrade_value("player", "max_health_reduction", 1)
	self._healing_reduction = managers.player:upgrade_value("player", "healing_reduction", 1)
	self._deflection = 1 - managers.player:body_armor_value("deflection", nil, 0) - managers.player:get_deflection_from_skills()
	self._revives = Application:digest_value(0, true)
	self._uppers_elapsed = 0

	self:replenish()

	local player_manager = managers.player
	self._bleed_out_health = Application:digest_value(tweak_data.player.damage.BLEED_OUT_HEALTH_INIT * player_manager:upgrade_value("player", "bleed_out_health_multiplier", 1), true)
	self._god_mode = Global.god_mode
	self._invulnerable = false
	self._mission_damage_blockers = {}
	self._gui = Overlay:newgui()
	self._ws = self._gui:create_screen_workspace()
	self._focus_delay_mul = 1
	self._dmg_interval = tweak_data.player.damage.MIN_DAMAGE_INTERVAL
	self._next_allowed_dmg_t = Application:digest_value(-100, true)
	self._last_received_dmg = 0
	self._next_allowed_sup_t = -100
	self._last_received_sup = 0
	self._supperssion_data = {}
	self._inflict_damage_body = self._unit:body("inflict_reciever")

	self._inflict_damage_body:set_extension(self._inflict_damage_body:extension() or {})

	local body_ext = PlayerBodyDamage:new(self._unit, self, self._inflict_damage_body)
	self._inflict_damage_body:extension().damage = body_ext

	managers.sequence:add_inflict_updator_body("fire", self._unit:key(), self._inflict_damage_body:key(), self._inflict_damage_body:extension().damage)

	--Load alternate heal over time tweakdata if player is using Infiltrator or Rogue.
	if player_manager:has_category_upgrade("player", "melee_stacking_heal") then
		self._doh_data = tweak_data.upgrades.melee_to_hot_data or {}
		self._hot_amount = managers.player:upgrade_value("player", "heal_over_time", 0)
	elseif player_manager:has_category_upgrade("player", "dodge_stacking_heal") then
		self._doh_data = tweak_data.upgrades.dodge_to_hot_data or {}
		self._hot_amount = managers.player:upgrade_value("player", "heal_over_time", 0)
	else 
		self._doh_data = tweak_data.upgrades.damage_to_hot_data or {}
		self._hot_amount = managers.player:upgrade_value("player", "damage_to_hot", 0)
	end

	self._damage_to_hot_stack = {}
	self._armor_stored_health = 0
	self._can_take_dmg_timer = 0
	self._regen_on_the_side_timer = 0
	self._regen_on_the_side = false
	self._interaction = managers.interaction
	self._armor_regen_mul = managers.player:upgrade_value("player", "armor_regen_time_mul", 1)
	self._dire_need = managers.player:has_category_upgrade("player", "armor_depleted_stagger_shot")
	self._has_damage_speed = managers.player:has_inactivate_temporary_upgrade("temporary", "damage_speed_multiplier")
	self._has_damage_speed_team = managers.player:upgrade_value("player", "team_damage_speed_multiplier_send", 0) ~= 0

	self._dodge_points = 0.0
	self._dodge_meter = 0.0 --Amount of dodge built up as meter. Caps at '150' dodge.
	self._dodge_meter_prev = 0.0 --dodge in meter from previous frame.
	self._in_smoke_bomb = 0.0 --0 = not in smoke, 1 = inside smoke, 2 = inside own smoke.
	self._can_survive_one_hit = player_manager:has_category_upgrade("player", "survive_one_hit")
	self._keep_health_on_revive = false
	self._biker_armor_regen_t = 0.0
	self._melee_push_multiplier = 1 - math.min(math.max(player_manager:upgrade_value("player", "resist_melee_push", 0.0) * self:_max_armor(), 0.0), 0.95)

	local function revive_player()
		self:revive(true)
	end

	managers.player:register_message(Message.RevivePlayer, self, revive_player)

	self._current_armor_fill = 0
	local has_swansong_skill = player_manager:has_category_upgrade("temporary", "berserker_damage_multiplier")
	self._current_state = nil
	self._listener_holder = unit:event_listener()

	if player_manager:has_category_upgrade("player", "damage_to_armor") then
		local damage_to_armor_data = player_manager:upgrade_value("player", "damage_to_armor", nil)
		local armor_data = tweak_data.blackmarket.armors[managers.blackmarket:equipped_armor(true, true)]

		if damage_to_armor_data and armor_data then
			local idx = armor_data.upgrade_level
			self._damage_to_armor = {
				armor_value = damage_to_armor_data[idx][1],
				target_tick = damage_to_armor_data[idx][2],
				elapsed = 0
			}


			local function on_damage(damage_info)
				local attacker_unit = damage_info and damage_info.attacker_unit

				if alive(attacker_unit) and attacker_unit:base() and attacker_unit:base().thrower_unit then
					attacker_unit = attacker_unit:base():thrower_unit()
				end

				if self._unit == attacker_unit then
					local time = Application:time()

					if self._damage_to_armor.target_tick < time - self._damage_to_armor.elapsed then
						self._damage_to_armor.elapsed = time

						self:restore_armor(self._damage_to_armor.armor_value, true)
					end
				end
			end

			CopDamage.register_listener("on_damage", {"on_damage"}, on_damage)
		end
	end

	self._listener_holder:add("on_use_armor_bag", {"on_use_armor_bag"}, callback(self, self, "_on_use_armor_bag_event"))

	if self:_init_armor_grinding_data() then

		function self._on_damage_callback_func()
			return callback(self, self, "_on_damage_armor_grinding")
		end

		self:_add_on_damage_event()
		self._listener_holder:add("on_enter_bleedout", {"on_enter_bleedout"}, callback(self, self, "_on_enter_bleedout_event"))

		if has_swansong_skill then
			self._listener_holder:add("on_enter_swansong", {"on_enter_swansong"}, callback(self, self, "_on_enter_swansong_event"))
			self._listener_holder:add("on_exit_swansong", {"on_enter_bleedout"}, callback(self, self, "_on_exit_swansong_event"))
		end

		self._listener_holder:add("on_revive", {"on_revive"}, callback(self, self, "_on_revive_event"))
	else
		self:_init_standard_listeners()
	end

	if player_manager:has_category_upgrade("temporary", "revive_damage_reduction") then
		self._listener_holder:add("combat_medic_damage_reduction", {"on_revive"}, callback(self, self, "_activate_combat_medic_damage_reduction"))
	end

	if player_manager:has_category_upgrade("player", "revive_damage_reduction") and player_manager:has_category_upgrade("player", "revive_damage_reduction") then

		local function on_revive_interaction_start()
			managers.player:set_property("revive_damage_reduction", player_manager:upgrade_value("player", "revive_damage_reduction"), 1)
		end


		local function on_exit_interaction()
			managers.player:remove_property("revive_damage_reduction")
		end


		local function on_revive_interaction_success()
			managers.player:activate_temporary_upgrade("temporary", "revive_damage_reduction")
		end

		self._listener_holder:add("on_revive_interaction_start", {"on_revive_interaction_start"}, on_revive_interaction_start)
		self._listener_holder:add("on_revive_interaction_interrupt", {"on_revive_interaction_interrupt"}, on_exit_interaction)
		self._listener_holder:add("on_revive_interaction_success", {"on_revive_interaction_success"}, on_revive_interaction_success)
	end

	managers.mission:add_global_event_listener("player_regenerate_armor", {"player_regenerate_armor"}, callback(self, self, "_regenerate_armor"))
	managers.mission:add_global_event_listener("player_force_bleedout", {"player_force_bleedout"}, callback(self, self, "force_into_bleedout", false))

	local level_tweak = tweak_data.levels[managers.job:current_level_id()]

	if level_tweak and level_tweak.is_safehouse and not level_tweak.is_safehouse_combat then
		self:set_mission_damage_blockers("damage_fall_disabled", true)
		self:set_mission_damage_blockers("invulnerable", true)
	end
	
	self._delayed_damage = {
		epsilon = 0.001,
		chunks = {}
	}

	managers.player:set_damage_absorption("absorption_addend", managers.player:upgrade_value("player", "damage_absorption_addend", 0))
end

function PlayerDamage:damage_melee(attack_data)
	local player_unit = managers.player:player_unit()
	if attack_data then
		if alive(attack_data.attacker_unit) then
			if tostring(attack_data.attacker_unit:base()._tweak_table) == "summers" or tostring(attack_data.attacker_unit:base()._tweak_table) == "fbi_vet_boss" then
				if alive(player_unit) then
					if self._invulnerable or self._mission_damage_blockers.invulnerable or self._god_mode or self:incapacitated() or self._unit:movement():current_state().immortal or self._unit:movement():current_state().driving then
					else
						player_unit:movement():on_non_lethal_electrocution()
						managers.player:set_player_state("tased")
					end
				end
			elseif tostring(attack_data.attacker_unit:base()._tweak_table) == "autumn" then
				if alive(player_unit) then
					if self._invulnerable or self._mission_damage_blockers.invulnerable or self._god_mode or self:incapacitated() or self._unit:movement():current_state().immortal or self._unit:movement():current_state().driving then
					else
						attack_data.attacker_unit:damage():run_sequence_simple("decloak")
						attack_data.attacker_unit:movement():set_uncloaked(true)
						attack_data.attacker_unit:sound():say("i03", true, nil, true)
						managers.player:set_player_state("arrested")
					end
				end			
			end		
		end
	end

	if not self:_chk_can_take_dmg() then
		return
	end

	local pm = managers.player
	local can_counter_strike = pm:has_category_upgrade("player", "counter_strike_melee")

	if can_counter_strike and self._unit:movement():current_state().in_melee and self._unit:movement():current_state():in_melee() then
		self._unit:movement():current_state():discharge_melee()

		return "countered"
	end

	local blood_effect = attack_data.melee_weapon and attack_data.melee_weapon == "weapon"
	blood_effect = blood_effect or attack_data.melee_weapon and tweak_data.weapon.npc_melee[attack_data.melee_weapon] and tweak_data.weapon.npc_melee[attack_data.melee_weapon].player_blood_effect or false

	if blood_effect then
		local pos = mvec1

		mvector3.set(pos, self._unit:camera():forward())
		mvector3.multiply(pos, 20)
		mvector3.add(pos, self._unit:camera():position())

		local rot = self._unit:camera():rotation():z()

		World:effect_manager():spawn({
			effect = Idstring("effects/payday2/particles/impacts/blood/blood_impact_a"),
			position = pos,
			normal = rot
		})
	end

	local dmg_mul = pm:damage_reduction_skill_multiplier("melee")
	attack_data.damage = attack_data.damage * dmg_mul

	self._unit:sound():play("melee_hit_body", nil, nil)

	local result = self:damage_bullet(attack_data)
	local vars = {
		"melee_hit",
		"melee_hit_var2"
	}

	self._unit:camera():play_shaker(vars[math.random(#vars)], math.max(1 * self._melee_push_multiplier, 0.2))

	if pm:current_state() == "bipod" then
		self._unit:movement()._current_state:exit(nil, "standard")
		pm:set_player_state("standard")
	end

	local push_vel = Vector3(attack_data.push_vel.x * self._melee_push_multiplier, attack_data.push_vel.y * self._melee_push_multiplier, attack_data.push_vel.z * self._melee_push_multiplier)
	self._unit:movement():push(push_vel)

	return result
end

local orig_dmg_xpl = PlayerDamage.damage_explosion	
function PlayerDamage:damage_explosion(attack_data,...)
	local attacker_unit = attack_data and attack_data.attacker_unit
	if attacker_unit then
		log("RES DEBUG STUFF: attacker team id is [" .. tostring(attacker_unit:movement():team().id) .. "], own team id is [" .. tostring(self._unit:movement():team().id) .. "]")
		if (attacker_unit:movement():team().id == self._unit:movement():team().id) or (self._unit == attacker_unit) then 
			return
		end
	end
	return orig_dmg_xpl(self,attack_data,...)
end 

--Lets you heal with full HP--
function PlayerDamage:full_revives(self)
	return Application:digest_value(self._revives, false) >= tweak_data.player.damage.LIVES_INIT + managers.player:upgrade_value("player", "additional_lives", 0)
end

local old_player_regenerated = PlayerDamage._regenerated
function PlayerDamage:_regenerated(no_messiah)
	old_player_regenerated(self, no_messiah)
	if no_messiah then
		managers.player:refill_messiah_charges()
	end

	managers.player:set_damage_absorption(
		"down_absorption",
		0
	)
end

local damage_bullet_original = PlayerDamage.damage_bullet
local _chk_dmg_too_soon_original = PlayerDamage._chk_dmg_too_soon

function PlayerDamage:damage_bullet(attack_data, ...)
	local damage_info = {
		result = {type = "hurt", variant = "bullet"},
		attacker_unit = attack_data.attacker_unit
	}
	
	if not self:_chk_can_take_dmg() then
		return
	elseif self._god_mode then
		if attack_data.damage > 0 then
			self:_send_damage_drama(attack_data, attack_data.damage)
		end
		self:_call_listeners(damage_info)
		return
	elseif self._invulnerable or self._mission_damage_blockers.invulnerable then
		self:_call_listeners(damage_info)
		return
	elseif self:incapacitated() then
		return
	elseif self:is_friendly_fire(attack_data.attacker_unit) then
		return
	elseif self:_chk_dmg_too_soon(attack_data.damage) then
		return
	elseif self._unit:movement():current_state().immortal then
		return
	elseif self._revive_miss and math.random() < self._revive_miss then
		self:play_whizby(attack_data.col_ray.position)
		return
	end
	
	local pm = managers.player
	if tweak_data.weapon.predatorshield then --shield mechanic
		if self._unit:inventory():check_player_shield() and attack_data and attack_data.col_ray.position and not self._unit:_is_interacting() then 
			local ply_camera = managers.player:player_unit():camera()
			local target_vec = attack_data.col_ray.position - ply_camera:position()
			local angle = target_vec:to_polar_with_reference(ply_camera:forward(), math.UP).spin
			if self._unit:inventory():akimbo_shield_enabled() then
				if (120 <= angle and angle <= 180) or (-180 <= angle and angle <= -120) then --120° Protection
					if ((not self._unit:_is_reloading() and (managers.player.RUN_AND_SHOOT or not self._unit:movement():running())) and not self._unit:movement():in_air()) then
						if (self._unit:movement():stamina() > 0) then
							if (self._unit:movement():crouching()) then
								self._unit:movement():subtract_stamina(attack_data.damage * 0.2)
								--self._unit:movement():_restart_stamina_regen_timer()
							else
								self._unit:movement():subtract_stamina(attack_data.damage * 0.3)
								self._unit:movement():_restart_stamina_regen_timer()
							end
							attack_data.damage = attack_data.damage * 0.2
						else
							attack_data.damage = attack_data.damage * 0.3
						end
					else
						attack_data.damage = attack_data.damage * 0.4
					end
				end
			--else
				--if (90 <= angle and angle <= 180) or (-180 <= angle and angle <= -90) then
				--	attack_data.damage = 0.0001
				--end
		end
	end

	self._last_received_dmg = attack_data.damage
	self._next_allowed_dmg_t = Application:digest_value(pm:player_timer():time() + self._dmg_interval, true)

	self._last_bullet_damage = attack_data.damage
	local next_allowed_dmg_t_old = self._next_allowed_dmg_t
	
	if self._next_allowed_dmg_t ~= next_allowed_dmg_t_old then
		self._last_received_dmg = self._last_bullet_damage
	end

	local dmg_mul = pm:damage_reduction_skill_multiplier("bullet")
	attack_data.damage = attack_data.damage * dmg_mul
	attack_data.damage = managers.mutators:modify_value("PlayerDamage:TakeDamageBullet", attack_data.damage)
	attack_data.damage = managers.modifiers:modify_value("PlayerDamage:TakeDamageBullet", attack_data.damage)

	local damage_absorption = pm:damage_absorption()
	if damage_absorption > 0 then
		attack_data.damage = math.max(0, attack_data.damage - damage_absorption)
	end
	
	self:fill_dodge_meter(self._dodge_points) --Getting attacked fills your dodge meter by your dodge stat.
	if self._dodge_meter >= 1.0 then --Dodge attacks if your meter is at '100'.
		self._unit:sound():play("pickup_fak_skill") --Feel free to replace if you know a better sound.
		if attack_data.damage > 0 then
			self:fill_dodge_meter(-1.0)
			self:_send_damage_drama(attack_data, 0)
		end
		self:_call_listeners(damage_info)
		self:play_whizby(attack_data.col_ray.position)
		self:_hit_direction(attack_data.attacker_unit:position())
		self._last_received_dmg = 10000.0 --SC pls no 10000 damage units.
		managers.player:send_message(Message.OnPlayerDodge)
		return	
	end

	if attack_data.attacker_unit:base()._tweak_table == "tank" then
		managers.achievment:set_script_data("dodge_this_fail", true)
	end

	if 0 < self:get_real_armor() then
		self._unit:sound():play("player_hit")
	else
		self._unit:sound():play("player_hit_permadamage")
		self:fill_dodge_meter(pm:upgrade_value("player", "health_damage_bonus_dodge", 0) * self._dodge_points)
	end
	
	local shake_armor_multiplier = pm:body_armor_value("damage_shake") * pm:upgrade_value("player", "damage_shake_multiplier", 1)
	local gui_shake_number = tweak_data.gui.armor_damage_shake_base / shake_armor_multiplier
	gui_shake_number = gui_shake_number + pm:upgrade_value("player", "damage_shake_addend", 0)
	shake_armor_multiplier = tweak_data.gui.armor_damage_shake_base / gui_shake_number
	local shake_multiplier = math.clamp(attack_data.damage, 0.2, 2) * shake_armor_multiplier
	
	self._unit:camera():play_shaker("player_bullet_damage", 1 * shake_multiplier)
	managers.rumble:play("damage_bullet")
	
	self:_hit_direction(attack_data.attacker_unit:position())
	pm:check_damage_carry(attack_data)
	
	attack_data.damage = managers.player:modify_value("damage_taken", attack_data.damage, attack_data)
	
	if self._bleed_out then
		self:_bleed_out_damage(attack_data)
		return
	end
	
	if not attack_data.ignore_suppression and not self:is_suppressed() then
		return
	end
	
	self:_check_chico_heal(attack_data)

	local armor_reduction_multiplier = 0
	
	if 0 >= self:get_real_armor() then
		armor_reduction_multiplier = 1
	end
	
	local health_subtracted = self:_calc_armor_damage(attack_data)
	
	if attack_data.armor_piercing then
		attack_data.damage = attack_data.damage - health_subtracted
		if not _G.IS_VR then
			managers.hud:activate_bloody_screen(0.75)
		end
	else
		attack_data.damage = attack_data.damage * armor_reduction_multiplier
	end
	
	health_subtracted = health_subtracted + self:_calc_health_damage(attack_data)
	
	if not self._bleed_out and health_subtracted > 0 then
		self:_send_damage_drama(attack_data, health_subtracted)
	elseif self._bleed_out and attack_data.attacker_unit and attack_data.attacker_unit:alive() and attack_data.attacker_unit:base()._tweak_table == "tank" then
		self._kill_taunt_clbk_id = "kill_taunt" .. tostring(self._unit:key())
		managers.enemy:add_delayed_clbk(self._kill_taunt_clbk_id, callback(self, self, "clbk_kill_taunt", attack_data), TimerManager:game():time() + 0.1 + 0.1 + 0.1)
	elseif self._bleed_out and attack_data.attacker_unit and attack_data.attacker_unit:alive() and attack_data.attacker_unit:base()._tweak_table == "spring" then
		self._kill_taunt_clbk_id = "kill_taunt" .. tostring(self._unit:key())
		managers.enemy:add_delayed_clbk(self._kill_taunt_clbk_id, callback(self, self, "clbk_kill_taunt_spring", attack_data), TimerManager:game():time() + 0.1 + 0.1 + 0.1)	
	elseif self._bleed_out and attack_data.attacker_unit and attack_data.attacker_unit:alive() and attack_data.attacker_unit:base()._tweak_table == "taser" then
		self._kill_taunt_clbk_id = "kill_taunt" .. tostring(self._unit:key())
		managers.enemy:add_delayed_clbk(self._kill_taunt_clbk_id, callback(self, self, "clbk_kill_taunt_tase", attack_data), TimerManager:game():time() + 0.1 + 0.1 + 0.1)	
	elseif self._bleed_out and attack_data.attacker_unit and attack_data.attacker_unit:alive() and attack_data.attacker_unit:base()._tweak_table == "taser_titan" then
		self._kill_taunt_clbk_id = "kill_taunt" .. tostring(self._unit:key())
		managers.enemy:add_delayed_clbk(self._kill_taunt_clbk_id, callback(self, self, "clbk_kill_taunt_tase", attack_data), TimerManager:game():time() + 0.1 + 0.1 + 0.1)	
	elseif self._bleed_out and attack_data.attacker_unit and attack_data.attacker_unit:alive() then
		self._kill_taunt_clbk_id = "kill_taunt" .. tostring(self._unit:key())
		managers.enemy:add_delayed_clbk(self._kill_taunt_clbk_id, callback(self, self, "clbk_kill_taunt_common", attack_data), TimerManager:game():time() + 0.1 + 0.1 + 0.1)			
	end
	
	pm:send_message(Message.OnPlayerDamage, nil, attack_data)
	self:_call_listeners(damage_info)
	
	local _time = math.floor(TimerManager:game():time())
	self.tase_time = self.tase_time or 0
	local player_unit = managers.player:player_unit()
	if attack_data then
		if alive(attack_data.attacker_unit) then
			if attack_data.attacker_unit:base()._tweak_table == "taser_titan" and self.tase_time < _time or attack_data.attacker_unit:base()._tweak_table == "taser_summers" and self.tase_time < _time then
				if alive(player_unit) then
					if self._invulnerable or self._mission_damage_blockers.invulnerable or self._god_mode or self:incapacitated() or self._unit:movement():current_state().immortal or self._unit:movement():current_state().driving then
					else
						attack_data.attacker_unit:sound():say("post_tasing_taunt")
						player_unit:movement():on_non_lethal_electrocution()
						managers.player:set_player_state("tased")
						attack_data.damage = attack_data.damage * 0
						self.tase_time = _time + 10
					end
				end
			end		
		end
	end		
	
	return 
end

function PlayerDamage:_chk_dmg_too_soon(damage, ...)
	return _chk_dmg_too_soon_original(self, self._last_bullet_damage or damage, ...)
end

function PlayerDamage:_upd_suppression(t, dt)
	local data = self._supperssion_data
	if not managers.player:has_category_upgrade("player", "suppression_resist") then
		if data.value then
			if t > data.decay_start_t then
				data.value = data.value - dt
				if data.value <= 0 then
					data.value = nil
					data.decay_start_t = nil
					managers.environment_controller:set_suppression_value(0, 0)
				end
			elseif data.value == tweak_data.player.suppression.max_value and self._regenerate_timer then
				self._listener_holder:call("suppression_max")
			end
			if data.value then
				managers.environment_controller:set_suppression_value(self:effective_suppression_ratio(), self:suppression_ratio())
			end
		end
	end
end

function PlayerDamage:revive(silent)
	if Application:digest_value(self._revives, false) == 0 then
		self._revive_health_multiplier = nil
		return
	end
	local arrested = self:arrested()
	managers.player:set_player_state("standard")
	if not silent then
		PlayerStandard.say_line(self, "s05x_sin")
	end
	self._bleed_out = false
	self._incapacitated = nil
	self._downed_timer = nil
	self._downed_start_time = nil
	if not arrested and not self._keep_health_on_revive then
		if managers.player:has_category_upgrade("player", "health_revive_max") then		
			self:set_health(self:_max_health() * tweak_data.player.damage.REVIVE_HEALTH_STEPS_W_SKILL[self._revive_health_i] * (self._revive_health_multiplier or 1) * managers.player:upgrade_value("player", "revived_health_regain", 1))
		else
			self:set_health(self:_max_health() * tweak_data.player.damage.REVIVE_HEALTH_STEPS[self._revive_health_i] * (self._revive_health_multiplier or 1) * managers.player:upgrade_value("player", "revived_health_regain", 1))
		end		
		
		self:set_armor(self:_max_armor())
		self._revive_health_i = math.min(#tweak_data.player.damage.REVIVE_HEALTH_STEPS, self._revive_health_i + 1)
		--self._down_time = math.max(tweak_data.player.damage.DOWNED_TIME_MIN, self._down_time - tweak_data.player.damage.DOWNED_TIME_DEC)
		self._revive_miss = 2
	end
	self:_regenerate_armor()
	managers.hud:set_player_health({
		current = self:get_real_health(),
		total = self:_max_health(),
		revives = Application:digest_value(self._revives, false)
	})
	self:_send_set_health()
	self:_set_health_effect()
	managers.hud:pd_stop_progress()
	self._revive_health_multiplier = nil
	self._listener_holder:call("on_revive")
	self._keep_health_on_revive = false
	if managers.player:has_inactivate_temporary_upgrade("temporary", "revived_damage_resist") then
		managers.player:activate_temporary_upgrade("temporary", "revived_damage_resist")
	end
	if managers.player:has_inactivate_temporary_upgrade("temporary", "increased_movement_speed") then
		managers.player:activate_temporary_upgrade("temporary", "increased_movement_speed")
	end
	if managers.player:has_inactivate_temporary_upgrade("temporary", "swap_weapon_faster") then
		managers.player:activate_temporary_upgrade("temporary", "swap_weapon_faster")
	end
	if managers.player:has_inactivate_temporary_upgrade("temporary", "reload_weapon_faster") then
		managers.player:activate_temporary_upgrade("temporary", "reload_weapon_faster")
	end
	if managers.player:has_category_upgrade("player", "dodge_on_revive") then
		self:fill_dodge_meter(3.0, true)
	end
	
	managers.player:deactivate_db_regen()

	managers.player:set_damage_absorption(
		"down_absorption",
		managers.player:upgrade_value("player", "damage_absorption_low_revives", 0) * self:get_missing_revives()
	)
end

function PlayerDamage:band_aid_health()
	if managers.platform:presence() == "Playing" and (self:arrested() or self:need_revive()) then
		return
	end
	self:change_health(tweak_data.upgrades.values.first_aid_kit.heal_amount * self._healing_reduction)
	
	self._said_hurt = false
	if math.rand(1) < managers.player:upgrade_value("first_aid_kit", "downs_restore_chance", 0) then
		self._revives = Application:digest_value(math.min(self._lives_init + managers.player:upgrade_value("player", "additional_lives", 0), Application:digest_value(self._revives, false) + 1), true)
		self._revive_health_i = math.max(self._revive_health_i - 1, 1)
		managers.environment_controller:set_last_life(1 >= Application:digest_value(self._revives, false))
		managers.player:set_damage_absorption(
			"down_absorption",
			managers.player:upgrade_value("player", "damage_absorption_low_revives", 0) * self:get_missing_revives()
		)
	end
end

function PlayerDamage:recover_health()
	if managers.platform:presence() == "Playing" and (self:arrested() or self:need_revive()) then
		self:revive(true)
	end

	self:restore_health(tweak_data.upgrades.values.doctor_bag.heal_amount)
	managers.player:activate_db_regen()

	managers.hud:set_player_health({
		current = self:get_real_health(),
		total = self:_max_health(),
		revives = Application:digest_value(self._revives, false)
	})
end

function PlayerDamage:get_missing_revives()
	return self._lives_init + managers.player:upgrade_value("player", "additional_lives", 0) - self:get_revives()
end

function PlayerDamage:_calc_health_damage(attack_data)
	local health_subtracted = 0
	health_subtracted = self:get_real_health()
	attack_data.damage = attack_data.damage * self._deflection

	if managers.player:has_category_upgrade("player", "dodge_stacking_heal") and attack_data.damage > 0.0 then --Rogue health regen.
		self._damage_to_hot_stack = {}
	end
	
	attack_data.damage = attack_data.damage * managers.player:upgrade_value("player", "real_health_damage_reduction", 1)
	self:change_health(-attack_data.damage)
	health_subtracted = health_subtracted - self:get_real_health()
	
	local trigger_skills = table.contains({
		"bullet",
		"explosion",
		"melee",
		"delayed_tick"
	}, attack_data.variant)

	if self:get_real_health() == 0 and trigger_skills then
		self:_chk_cheat_death()
	end
	
	self:_damage_screen()
	self:_check_bleed_out(trigger_skills)
	managers.hud:set_player_health({
		current = self:get_real_health(),
		total = self:_max_health(),
		revives = Application:digest_value(self._revives, false)
	})
	self:_send_set_health()
		self:_set_health_effect()
		managers.statistics:health_subtracted(health_subtracted)
		return health_subtracted
end

function PlayerDamage:clbk_kill_taunt_spring(attack_data)
	if attack_data.attacker_unit and attack_data.attacker_unit:alive() then
		self._kill_taunt_clbk_id = nil

		attack_data.attacker_unit:sound():say("a02")
	end
end		

function PlayerDamage:clbk_kill_taunt_tase(attack_data)
	if attack_data.attacker_unit and attack_data.attacker_unit:alive() then
		self._kill_taunt_clbk_id = nil

		attack_data.attacker_unit:sound():say("post_tasing_taunt")
	end
end		

function PlayerDamage:clbk_kill_taunt_common(attack_data)
	if attack_data.attacker_unit and attack_data.attacker_unit:alive() then
		if not attack_data.attacker_unit:base()._tweak_table then
			return
		end
		self._kill_taunt_clbk_id = nil

		attack_data.attacker_unit:sound():say("i03")
	end
end	

function PlayerDamage:on_arrested()
	self._bleed_out = false
	self._arrested_timer = tweak_data.player.damage.ARRESTED_TIME * managers.player:upgrade_value("player", "pick_lock_easy_speed_multiplier", 1)
	self._arrested_paused_counter = 0

	managers.hud:pd_start_timer({time = self._arrested_timer})
	managers.hud:on_arrested()
end

function PlayerDamage:damage_tase(attack_data)
	if self._god_mode then
		return
	end
	
	local cur_state = self._unit:movement():current_state_name()
	
	if cur_state ~= "tased" and cur_state ~= "fatal" then
		self:on_tased(false)
	
		self._tase_data = attack_data
	
		managers.player:set_player_state("tased")
	
		local damage_info = {
			result = {
				variant = "tase",
				type = "hurt"
			}
		}
	
		self:_call_listeners(damage_info)
	
		if attack_data.attacker_unit and attack_data.attacker_unit:alive() and attack_data.attacker_unit:base()._tweak_table == "taser" then
			attack_data.attacker_unit:sound():say("post_tasing_taunt")
 
			if managers.blackmarket:equipped_mask().mask_id == tweak_data.achievement.its_alive_its_alive.mask then
				managers.achievment:award_progress(tweak_data.achievement.its_alive_its_alive.stat)
			end
		end
	end
	if cur_state == "tased" then
		if attack_data.attacker_unit:base()._tweak_table == "taser" or attack_data.attacker_unit:base()._tweak_table == "taser_titan" then
		   attack_data.attacker_unit:sound():say("post_tasing_taunt")
		end
	end	
end

function PlayerDamage:_max_armor()
	local max_armor = self:_raw_max_armor()

	if managers.player:has_category_upgrade("player", "armor_to_health_conversion") then
		max_armor = 0
	end

	return max_armor
end

function PlayerDamage:_update_regenerate_timer(t, dt)
	local regenerate_timer_tick = dt * (self._regenerate_speed or 1)

	--Smoke grenade armor regen bonus.
	if self._in_smoke_bomb > 0 then
		regenerate_timer_tick = regenerate_timer_tick * tweak_data.upgrades.smoke_screen_armor_regen[1]
	end

	self._regenerate_timer = math.max(self._regenerate_timer - regenerate_timer_tick, 0)

	if self._regenerate_timer <= 0 then
		self:_regenerate_armor()
	end
end

function PlayerDamage:set_dodge_points()
	self._dodge_points = (tweak_data.player.damage.DODGE_INIT 
		+managers.player:body_armor_value("dodge")
		+managers.player:skill_dodge_chance(false, false, false))
		or 0.0
	if self._dodge_points > 0 then
		managers.hud:unhide_dodge_panel(self._dodge_points)
	end
end

function PlayerDamage:get_dodge_points()
	return self._dodge_points
end

--Adds to/Subtracts from dodge meter and updates hud element.
function PlayerDamage:fill_dodge_meter(dodge_added, overfill)
	if self._dodge_points > 0 and not self:is_downed() then
		if overfill or (self._dodge_meter >= 1.5 and dodge_added < 0) then
			self._dodge_meter = math.max(self._dodge_meter + dodge_added, 0.0)
		elseif self._dodge_meter < 1.5 then
			self._dodge_meter = math.max(math.min(self._dodge_meter + dodge_added, 1.5), 0.0)
		end
	elseif self:is_downed() then
		self._dodge_meter = 0.0
	end
end

function PlayerDamage:fill_dodge_meter_yakuza(percent_added)
	self:fill_dodge_meter(percent_added * self._dodge_points * (1 - self:health_ratio()))
end

function PlayerDamage:cloak_or_shock_incap(damage)
	self:change_health(-1.0 * damage * managers.player:upgrade_value("player", "spooc_damage_resist", 1.0) or 0.0)

	if self:get_real_health() == 0 then
		self:change_health(0.1)
	end
	self._keep_health_on_revive = true
end

Hooks:PostHook(PlayerDamage, "update" , "ResDodgeMeterMovementUpdate" , function(self, unit, t, dt)
	local pm = managers.player
	self._in_smoke_bomb = 0.0
	for _, smoke_screen in ipairs(pm._smoke_screen_effects or {}) do
		if smoke_screen:is_in_smoke(self._unit) then
			if smoke_screen:mine() then
				self._in_smoke_bomb = 2.0
			else
				self._in_smoke_bomb = 1.0
			end
		end
	end

	--Add passive dodge increases. Start with bot dodge boost.
	local passive_dodge = pm:upgrade_value("team", "crew_add_dodge", 0)

	--Yakuza capstone skill.
	if self:health_ratio() < 0.5 then
		passive_dodge = passive_dodge + (1 - self:health_ratio()) * pm:upgrade_value("player", "dodge_regen_damage_health_ratio_multiplier", 0)
	end

	--Sicario capstone skill.
	if self._in_smoke_bomb == 2.0 then
		passive_dodge = passive_dodge + pm:upgrade_value("player", "sicario_multiplier", 0)
	end

	--Burglar capstone skill.
	if self._unit:movement():crouching() then
		passive_dodge = passive_dodge + pm:upgrade_value("player", "crouch_dodge_chance", 0)
	end

	--Duck and Cover aced.
	if self._unit:movement():running() then
		passive_dodge = passive_dodge + pm:upgrade_value("player", "run_dodge_chance", 0)
	elseif self._unit:movement():zipline_unit() then
		passive_dodge = passive_dodge + pm:upgrade_value("player", "on_zipline_dodge_chance", 0)
	end

	self:fill_dodge_meter(self._dodge_points * dt * passive_dodge)

	if self._dodge_meter ~= self._dodge_meter_prev then
		managers.hud:set_dodge_value(math.min(self._dodge_meter, 1.5)) --Update UI element once per frame.
		self._dodge_meter_prev = self._dodge_meter
	end

	--Biker Armor Regen
	if pm:has_category_upgrade("player", "biker_armor_regen") then
		self:tick_biker_armor_regen(dt)
	end
end)

function PlayerDamage:_upd_health_regen(t, dt)
	if self._health_regen_update_timer then
		self._health_regen_update_timer = self._health_regen_update_timer - dt

		if self._health_regen_update_timer <= 0 then
			self._health_regen_update_timer = nil
		end
	end

	if not self._health_regen_update_timer then
		local max_health = self:_max_health()

		if self:get_real_health() < max_health then
			local regened_health = managers.player:health_regen_2() * max_health + managers.player:fixed_health_regen_2()
			self:restore_health(regened_health, true)

			self._health_regen_update_timer = 4
		end
	end

	if #self._damage_to_hot_stack > 0 then
		repeat
			local next_doh = self._damage_to_hot_stack[1]
			local done = not next_doh or TimerManager:game():time() < next_doh.next_tick

			if not done then
				local regen_rate = self._hot_amount --All this for a single line change so stacking health regen isn't coupled to grinder. :)

				self:restore_health(regen_rate, true)

				next_doh.ticks_left = next_doh.ticks_left - 1

				if next_doh.ticks_left == 0 then
					table.remove(self._damage_to_hot_stack, 1)
				else
					next_doh.next_tick = next_doh.next_tick + (self._doh_data.tick_time or 1)
				end

				table.sort(self._damage_to_hot_stack, function (x, y)
					return x.next_tick < y.next_tick
				end)
			end
		until done
	end
end

function PlayerDamage:restore_health(health_restored, is_static, chk_health_ratio)
	log("pls work")
	if chk_health_ratio and managers.player:is_damage_health_ratio_active(self:health_ratio()) then
		return false
	end
	log("2")
	if is_static then
		return self:change_health(health_restored * self._healing_reduction)
	else
		local max_health = self:_max_health()

		return self:change_health(max_health * health_restored * self._healing_reduction)
	end
end


Hooks:PreHook(PlayerDamage, "_check_bleed_out", "ResYakuzaCaptstoneCheck", function(self, can_activate_berserker, ignore_movement_state)
	if self._check_berserker_done then
		if self._can_survive_one_hit then
			self._can_survive_one_hit = false
		end
	end
	if self:get_real_health() == 0 and not self._check_berserker_done then
		if self._can_survive_one_hit then
			self:change_health(0.1)
			self._can_survive_one_hit = false
			self:restore_armor(tweak_data.upgrades.values.survive_one_hit_armor[1])
		else
			self._can_survive_one_hit = managers.player:has_category_upgrade("player", "survive_one_hit")
		end
	end
end)

Hooks:PostHook(PlayerDamage, "_calc_armor_damage", "ResBikerCooldown", function(self, attack_data)
	if self._biker_armor_regen_t == 0.0 and managers.player:has_category_upgrade("player", "biker_armor_regen") then
		self._biker_armor_regen_t = managers.player:upgrade_value("player", "biker_armor_regen")[2]
	end
end)

function PlayerDamage:tick_biker_armor_regen(amount)
	if self:get_real_armor() == self:_max_armor() then
		self._biker_armor_regen_t = 0.0
		return
	end

	self._biker_armor_regen_t = self._biker_armor_regen_t - amount
	if self._biker_armor_regen_t <= 0.0 then
		self:restore_armor(managers.player:upgrade_value("player", "biker_armor_regen")[1])
		self._biker_armor_regen_t = self._biker_armor_regen_t + managers.player:upgrade_value("player", "biker_armor_regen")[2]
	end
end

function PlayerDamage:consume_messiah_charge()
	if managers.player:has_category_upgrade("player", "infinite_messiah") then
		return true
	elseif self:got_messiah_charges() then
		self._messiah_charges = self._messiah_charges - 1
		return true
	end

	return false
end

function PlayerManager:health_regen()
	local health_regen = tweak_data.player.damage.HEALTH_REGEN
	health_regen = health_regen + self:temporary_upgrade_value("temporary", "wolverine_health_regen", 0)
	health_regen = health_regen + self:upgrade_value("player", "passive_health_regen", 0)

	return health_regen
end

function PlayerManager:fixed_health_regen(health_ratio)
	local health_regen = 0

	if not health_ratio or not self:is_damage_health_ratio_active(health_ratio) then
		health_regen = health_regen + self:upgrade_value("team", "crew_health_regen", 0)
	end

	health_regen = health_regen + self:get_hostage_bonus_addend("health_regen")
	return health_regen
end