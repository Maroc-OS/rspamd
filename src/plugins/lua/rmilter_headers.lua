--[[
Copyright (c) 2016, Andrew Lewis <nerf@judo.za.org>
Copyright (c) 2016, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--

-- A plugin that provides common header manipulations

local logger = require "rspamd_logger"
local N = 'rmilter_headers'
local E = {}

local settings = {
  routines = {
    ['spam-header'] = {
      header = 'Deliver-To',
      value = 'Junk',
      remove = 1,
    },
    ['x-virus'] = {
      header = 'X-Virus',
      remove = 1,
      symbols = {}, -- needs config
    },
    ['x-spamd-bar'] = {
      header = 'X-Spamd-Bar',
      positive = '+',
      negative = '-',
      neutral = '/',
      remove = 1,
    },
    ['x-spam-level'] = {
      header = 'X-Spam-Level',
      char = '*',
      remove = 1,
    },
    ['x-spam-status'] = {
      header = 'X-Spam-Status',
      remove = 1,
    },
    ['authentication-results'] = {
      header = 'Authentication-Results',
      remove = 1,
      spf_symbols = {
        pass = 'R_SPF_ALLOW',
        fail = 'R_SPF_FAIL',
        softfail = 'R_SPF_SOFTFAIL',
        neutral = 'R_SPF_NEUTRAL',
        temperror = 'R_SPF_DNSFAIL',
        none = 'R_SPF_NA',
        permerror = 'R_SPF_PERMFAIL',
      },
      dkim_symbols = {
        pass = 'R_DKIM_ALLOW',
        fail = 'R_DKIM_REJECT',
        temperror = 'R_DKIM_TEMPFAIL',
        none = 'R_DKIM_NA',
        permerror = 'R_DKIM_PERMFAIL',
      },
      dmarc_symbols = {
        pass = 'DMARC_POLICY_ALLOW',
        permerror = 'DMARC_BAD_POLICY',
        temperror = 'DMARC_DNSFAIL',
        none = 'DMARC_NA',
        reject = 'DMARC_POLICY_REJECT',
        softfail = 'DMARC_POLICY_SOFTFAIL',
        quarantine = 'DMARC_POLICY_QUARANTINE',
      },
    },
  },
}

local active_routines = {}
local custom_routines = {}

local function rmilter_headers(task)

  local routines, common, add, remove = {}, {}, {}, {}

  routines['x-spamd-bar'] = function()
    if not common['metric_score'] then
      common['metric_score'] = task:get_metric_score('default')
    end
    local score = common['metric_score'][1]
    local spambar
    if score <= -1 then
      spambar = string.rep(settings.routines['x-spamd-bar'].negative, score*-1)
    elseif score >= 1 then
      spambar = string.rep(settings.routines['x-spamd-bar'].positive, score)
    else
      spambar = settings.routines['x-spamd-bar'].neutral
    end
    if settings.routines['x-spamd-bar'].remove then
      remove[settings.routines['x-spamd-bar'].header] = settings.routines['x-spamd-bar'].remove
    end
    if spambar ~= '' then
      add[settings.routines['x-spamd-bar'].header] = spambar
    end
  end

  routines['x-spam-level'] = function()
    if not common['metric_score'] then
      common['metric_score'] = task:get_metric_score('default')
    end
    local score = common['metric_score'][1]
    if score < 1 then
      return nil, {}, {}
    end
    if settings.routines['x-spam-level'].remove then
      remove[settings.routines['x-spam-level'].header] = settings.routines['x-spam-level'].remove
    end
    add[settings.routines['x-spam-level'].header] = string.rep(settings.routines['x-spam-level'].char, score)
  end

  routines['spam-header'] = function()
    if not common['metric_action'] then
      common['metric_action'] = task:get_metric_action('default')
    end
    if settings.routines['spam-header'].remove then
      remove[settings.routines['spam-header'].header] = settings.routines['spam-header'].remove
    end
    local action = common['metric_action']
    if action ~= 'no action' and action ~= 'greylist' then
      add[settings.routines['spam-header'].header] = settings.routines['spam-header'].value
    end
  end

  routines['x-virus'] = function()
    if not common.symbols then
      common.symbols = {}
    end
    if settings.routines['x-virus'].remove then
      remove[settings.routines['x-virus'].header] = settings.routines['x-virus'].remove
    end
    local virii = {}
    for _, sym in ipairs(settings.routines['x-virus'].symbols) do
      if not (common.symbols[sym] == false) then
	local s = task:get_symbol(sym)
	if not s then
	  common.symbols[sym] = false
	else
	  common.symbols[sym] = s
	  if (((s or E)[1] or E).options or E)[1] then
	    table.insert(virii, s[1].options[1])
	  else
	    table.insert(virii, 'unknown')
	  end
	end
      end
    end
    if #virii > 0 then
      add[settings.routines['x-virus'].header] = table.concat(virii, ',')
    end
  end

  routines['x-spam-status'] = function()
    if not common['metric_score'] then
      common['metric_score'] = task:get_metric_score('default')
    end
    if not common['metric_action'] then
      common['metric_action'] = task:get_metric_action('default')
    end
    local score = common['metric_score'][1]
    local action = common['metric_action']
    local is_spam
    local spamstatus
    if action ~= 'no action' and action ~= 'greylist' then
      is_spam = 'Yes'
    else
      is_spam = 'No'
    end
    spamstatus = is_spam .. ', score=' .. string.format('%.2f', score)
    if settings.routines['x-spam-status'].remove then
      remove[settings.routines['x-spam-status'].header] = settings.routines['x-spam-status'].remove
    end
    add[settings.routines['x-spam-status'].header] = spamstatus
  end

  routines['authentication-results'] = function()
    local auth_results, hdr_parts = {}, {}
    if not common.symbols then
      common.symbols = {}
    end
    local auth_types = {
      dkim = settings.routines['authentication-results'].dkim_symbols,
      dmarc = settings.routines['authentication-results'].dmarc_symbols,
      spf = settings.routines['authentication-results'].spf_symbols,
    }
    for auth_type, symbols in pairs(auth_types) do
      for key, sym in pairs(symbols) do
	if not (common.symbols[sym] == false) then
	  local s = task:get_symbol(sym)
	  if not s then
	    common.symbols[sym] = false
	  else
	    common.symbols[sym] = s
	    if not auth_results[auth_type] then
	      auth_results[auth_type] = {key}
	    else
	      table.insert(auth_results[auth_type], key)
	    end
	    if auth_type ~= 'dkim' then
	      break
	    end
	  end
	end
      end
    end
    if settings.routines['authentication-results'].remove then
      remove[settings.routines['authentication-results'].header] = settings.routines['authentication-results'].remove
    end
    for auth_type, keys in pairs(auth_results) do
      for _, key in ipairs(keys) do
	local hdr = ''
	if auth_type == 'dmarc' and key ~= 'none' then
	  hdr = hdr .. 'dmarc='
	  if key == 'reject' or key == 'quarantine' or key == 'softfail' then
	    hdr = hdr .. 'fail'
	  else
	    hdr = hdr .. key
	  end
	  if key == 'pass' then
	    hdr = hdr .. ' policy=' .. common.symbols[auth_types['dmarc'][key]][1]['options'][2]
	    hdr = hdr .. ' header.from=' .. common.symbols[auth_types['dmarc'][key]][1]['options'][1]
	  elseif key ~= 'none' then
	    local t = rspamd_str_split(common.symbols[auth_types['dmarc'][key]][1]['options'][1], ' : ')
	    local dom = t[1]
	    local rsn = t[2]
	    hdr = hdr .. ' reason="' .. rsn .. '"'
	    hdr = hdr .. ' header.from=' .. dom
	    if key == 'softfail' then
	      hdr = hdr .. ' policy=none'
	    else
	      hdr = hdr .. ' policy=' .. key
	    end
	  end
	  table.insert(hdr_parts, hdr)
	elseif auth_type == 'dkim' and key ~= 'none' then
	  if common.symbols[auth_types['dkim'][key]][1] then
	    for _, v in ipairs(common.symbols[auth_types['dkim'][key]][1]['options']) do
	      hdr = hdr .. auth_type .. '=' .. key .. ' header.d=' .. v
	      table.insert(hdr_parts, hdr)
	    end
	  end
	elseif auth_type == 'spf' and key ~= 'none' then
	  hdr = hdr .. auth_type .. '=' .. key
	  local smtp_from = task:get_from('smtp')
	  if smtp_from['addr'] ~= '' and smtp_from['addr'] ~= nil then
	    hdr = hdr .. ' smtp.mailfrom=' .. smtp_from['addr']
	  else
	    local helo = task:get_helo()
	    if helo then
	      hdr = hdr .. ' smtp.helo=' .. task:get_helo()
	    end
	  end
	  table.insert(hdr_parts, hdr)
	end
      end
    end
    if #hdr_parts > 0 then
      add[settings.routines['authentication-results'].header] = table.concat(hdr_parts, '; ')
    end
  end

  for _, n in ipairs(active_routines) do
    local ok, err
    if custom_routines[n] then
      local to_add, to_remove, common_in
      ok, err, to_add, to_remove, common_in = pcall(custom_routines[n], task, common)
      if ok then
        for k, v in pairs(to_add) do
          add[k] = v
        end
        for k, v in pairs(to_remove) do
          add[k] = v
        end
        for k, v in pairs(common_in) do
          if type(v) == 'table' then
            if not common[k] then
              common[k] = {}
            end
            for kk, vv in pairs(v) do
              common[k][kk] = vv
            end
          else
            common[k] = v
          end
        end
      end
    else
      ok, err = pcall(routines[n])
    end
    if not ok then
      logger.errx(task, 'call to %s failed: %s', n, err)
    end
  end

  if not next(add) then add = nil end
  if not next(remove) then remove = nil end
  if add or remove then
    task:set_rmilter_reply({
      add_headers = add,
      remove_headers = remove
    })
  end
end

local opts = rspamd_config:get_all_opt(N)
if not opts then return end
if type(opts['use']) == 'string' then
  opts['use'] = {opts['use']}
end
if type(opts['use']) ~= 'table' then
  logger.errx(rspamd_config, 'unexpected type for "use" option: %s', type(opts['use']))
  return
end
if type(opts['custom']) == 'table' then
  for k, v in pairs(opts['custom']) do
    local f, err = load(v)
    if not f then
      logger.errx(rspamd_config, 'could not load "%s": %s', k, err)
    else
      custom_routines[k] = f()
    end
  end
end
for _, s in ipairs(opts['use']) do
  if settings.routines[s] or custom_routines[s] then
    table.insert(active_routines, s)
    if (opts.routines and opts.routines[s]) then
      for k, v in pairs(opts.routines[s]) do
        settings.routines[s][k] = v
      end
    end
  else
    logger.errx(rspamd_config, 'routine "%s" does not exist', s)
  end
end
if (#active_routines < 1) then
  logger.errx(rspamd_config, 'no active routines')
  return
end
logger.infox(rspamd_config, 'active routines [%s]', table.concat(active_routines, ','))
rspamd_config:register_symbol({
  name = 'RMILTER_HEADERS',
  type = 'postfilter',
  callback = rmilter_headers,
  priority = 10
})
