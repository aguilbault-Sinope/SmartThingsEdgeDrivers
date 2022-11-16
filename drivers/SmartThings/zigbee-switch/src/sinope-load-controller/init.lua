-- Copyright 2022 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local capabilities              = require "st.capabilities"
local clusters                  = require "st.zigbee.zcl.clusters"
local cluster_base              = require "st.zigbee.cluster_base"
local configurationMap          = require "configurations"
local data_types                = require "st.zigbee.data_types"
local device_management         = require "st.zigbee.device_management"
local constants                 = require "st.zigbee.constants"
-- local ApplianceEventsAlerts     = clusters.ApplianceEventsAlerts
local TemperatureMeasurement    = clusters.TemperatureMeasurement
local SimpleMetering            = clusters.SimpleMetering
local ElectricalMeasurement     = clusters.ElectricalMeasurement

local SINOPE_SWITCH_CLUSTER = 0xFF01
local SINOPE_MAX_INTENSITY_ON_ATTRIBUTE = 0x0052
local SINOPE_MAX_INTENSITY_OFF_ATTRIBUTE = 0x0053

local RM3500ZB_CONFIGURATION = {
  {
    cluster = TemperatureMeasurement.ID,
    attribute = TemperatureMeasurement.attributes.MeasuredValue.ID,
    minimum_interval = 30,
    maximum_interval = 300,
    data_type = TemperatureMeasurement.attributes.MeasuredValue.base_type,
    reportable_change = 1
  }
}

-- local handle_alerts_notification_payload = function(driver, device, zb_rx)
--   local alert_struct = zb_rx.body.zcl_body.alert_structure_list[1]

--   if alert_struct:get_alert_id() == 0x81 then
--     local is_wet = alert_struct:get_category() == 0x01 and alert_struct:get_presence_recovery() == 0x01
--     device:emit_event_for_endpoint(
--       zb_rx.address_header.src_endpoint.value,
--       is_wet and capabilities.waterSensor.water.wet() or capabilities.waterSensor.water.dry())
--   end
-- end

local temperature_value_attr_handler = function(driver, device, value, zb_rx)
  local raw_temp = value.value
  local celc_temp = raw_temp / 100.0
  local temp_scale = "C"

  device:emit_event_for_endpoint(
    zb_rx.address_header.src_endpoint.value,
    celc_temp <= 0 and capabilities.temperatureAlarm.temperatureAlarm.freeze() or capabilities.temperatureAlarm.temperatureAlarm.cleared())

  device:emit_event_for_endpoint(
    zb_rx.address_header.src_endpoint.value,
    capabilities.temperatureMeasurement.temperature({value = celc_temp, unit = temp_scale }))
end 

local function added_handler(self, device)
  device:emit_event(capabilities.waterSensor.water.dry())
end

local function component_to_endpoint(device, component_id)
  local ep_num = component_id:match("switch(%d)")
  return ep_num and tonumber(ep_num) or device.fingerprinted_endpoint_id
end

local function endpoint_to_component(device, ep)
  local switch_comp = string.format("switch%d", ep)
  if device.profile.components[switch_comp] ~= nil then
    return switch_comp
  else
    return "main"
  end
end

local do_configure = function(self, device)
  device:refresh()
  device:configure()

  -- Additional one time configuration
  if device:supports_capability(capabilities.energyMeter) or device:supports_capability(capabilities.powerMeter) then
    -- Divisor and multipler for EnergyMeter
    device:send(ElectricalMeasurement.attributes.ACPowerDivisor:read(device))
    device:send(ElectricalMeasurement.attributes.ACPowerMultiplier:read(device))
    -- Divisor and multipler for PowerMeter
    device:send(SimpleMetering.attributes.Divisor:read(device))
    device:send(SimpleMetering.attributes.Multiplier:read(device))
  end
  device:send(device_management.build_bind_request(device, ApplianceEventsAlerts.ID, self.environment_info.hub_zigbee_eui))
  device:send(device_management.build_bind_request(device, TemperatureMeasurement.ID, self.environment_info.hub_zigbee_eui))
  device:send(TemperatureMeasurement.attributes.MeasuredValue:read(device))
  device:send(TemperatureMeasurement.attributes.MeasuredValue:configure_reporting(device, 30, 300, 1):to_endpoint(0x01))
end

local function device_init(driver, device)
  print("device_init")

  device:set_component_to_endpoint_fn(component_to_endpoint)
  device:set_endpoint_to_component_fn(endpoint_to_component)

  for _, attribute in ipairs(RM3500ZB_CONFIGURATION) do
    device:add_configured_attribute(attribute)
    device:add_monitored_attribute(attribute)
  end
end

local function info_changed(driver, device, event, args)
  -- handle ledIntensity preference setting
  if (args.old_st_store.preferences.ledIntensity ~= device.preferences.ledIntensity) then
    local ledIntensity = device.preferences.ledIntensity

    device:send(cluster_base.write_attribute(device,
                data_types.ClusterId(SINOPE_SWITCH_CLUSTER),
                data_types.AttributeId(SINOPE_MAX_INTENSITY_ON_ATTRIBUTE),
                data_types.validate_or_build_type(ledIntensity, data_types.Uint8, "payload")))
    device:send(cluster_base.write_attribute(device,
                data_types.ClusterId(SINOPE_SWITCH_CLUSTER),
                data_types.AttributeId(SINOPE_MAX_INTENSITY_OFF_ATTRIBUTE),
                data_types.validate_or_build_type(ledIntensity, data_types.Uint8, "payload")))

  end
end

local zigbee_sinope_switch = {
  NAME = "Zigbee Sinope switch",
  supported_capabilities = {
    capabilities.switch,
    capabilities.switchLevel,
    capabilities.colorControl,
    capabilities.colorTemperature,
    capabilities.powerMeter,
    capabilities.energyMeter,
    capabilities.motionSensor,
    capabilities.temperatureMeasurement,
    capabilities.waterSensor
  },
  lifecycle_handlers = {
    init = device_init,
    infoChanged = info_changed,
    doConfigure = do_configure,
    added = added_handler
  },
  zigbee_handlers = {
    attr = {
      -- [ApplianceEventsAlerts.ID] = {
      --   [ApplianceEventsAlerts.client.commands.AlertsNotification.ID] = handle_alerts_notification_payload,
      -- },
      [TemperatureMeasurement.ID] = {
        [TemperatureMeasurement.attributes.MeasuredValue.ID] = temperature_value_attr_handler
      }
    }
  },
  ias_zone_config_method = constants.IAS_ZONE_CONFIGURE_TYPE.AUTO_ENROLL_RESPONSE,
  can_handle = function(opts, driver, device, ...)
       return device:get_manufacturer() == "Sinope Technologies" and device:get_model() == "RM3500ZB"
  end
}

return zigbee_sinope_switch
