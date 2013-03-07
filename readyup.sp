#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <left4downtown>

#define MAX_FOOTERS 10
#define MAX_FOOTER_LEN 65

public Plugin:myinfo =
{
	name = "L4D2 Ready-Up",
	author = "CanadaRox",
	description = "New and improved ready-up plugin.",
	version = "1",
	url = ""
};

enum L4D2Team
{
	L4D2Team_None = 0,
	L4D2Team_Spectator,
	L4D2Team_Survivor,
	L4D2Team_Infected
}

// Plugin Cvars
new Handle:l4d_ready_disable_spawns;
new Handle:l4d_ready_server_cfg;

// Game Cvars
new Handle:director_no_mobs;
new Handle:director_no_specials;
new Handle:god;
new Handle:sb_stop;
new Handle:survivor_limit;
new Handle:z_common_limit;
new Handle:z_ghost_delay_max;
new Handle:z_ghost_delay_min;
new Handle:z_max_player_zombies;
new z_common_limit_initial;
new z_ghost_delay_max_initial;
new z_ghost_delay_min_initial;

new Handle:casterTrie;
new Handle:liveForward;
new Handle:menuPanel;
new Handle:readyCountdownTimer;
new String:readyFooter[MAX_FOOTERS][MAX_FOOTER_LEN];
new bool:inLiveCountdown = false;
new bool:inReadyUp;
new bool:isPlayerReady[MAXPLAYERS + 1];
new footerCounter = 0;
new readyDelay;
new casterCount = 0;

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	CreateNative("AddStringToReadyFooter", Native_AddStringToReadyFooter);
	CreateNative("IsInReady", Native_IsInReady);
	liveForward = CreateGlobalForward("OnRoundIsLive", ET_Event);
	return APLRes_Success;
}

public OnPluginStart()
{
	CreateConVar("l4d_ready_enabled", "1", "This cvar doesn't do anything, but if it is 0 the logger wont log this game.");
	l4d_ready_server_cfg = CreateConVar("l4d_ready_server_cfg", "", "Configname to display on the ready-up panel");
	l4d_ready_disable_spawns = CreateConVar("l4d_ready_disable_spawns", "0", "Prevent SI from having spawns during ready-up");

	HookEvent("round_start", RoundStart_Event);

	director_no_mobs = FindConVar("director_no_mobs");
	director_no_specials = FindConVar("director_no_specials");
	god = FindConVar("god");
	sb_stop = FindConVar("sb_stop");
	survivor_limit = FindConVar("survivor_limit");
	z_common_limit = FindConVar("z_common_limit");
	z_ghost_delay_max = FindConVar("z_ghost_delay_max");
	z_ghost_delay_min = FindConVar("z_ghost_delay_min");
	z_max_player_zombies = FindConVar("z_max_player_zombies");

	RegAdminCmd("sm_caster", Caster_Cmd, ADMFLAG_BAN);
	RegAdminCmd("sm_forcestart", ForceStart_Cmd, ADMFLAG_BAN);
	RegConsoleCmd("sm_notcasting", NotCasting_Cmd);
	RegConsoleCmd("sm_ready", Ready_Cmd);
	RegConsoleCmd("sm_toggleready", ToggleReady_Cmd);
	RegConsoleCmd("sm_unready", Unready_Cmd);

	// Debug Commands
	RegConsoleCmd("sm_initready", InitReady_Cmd);
	RegConsoleCmd("sm_initlive", InitLive_Cmd);
	casterTrie = CreateTrie();
}

public OnMapStart()
{
	/* OnMapEnd needs this to work */
}

/* This ensures all cvars are reset if the map is changed during ready-up */
public OnMapEnd()
{
	if (inReadyUp)
		InitiateLive();
}

public OnClientDisconnect(client)
{
	decl String:buffer[64];
	GetClientAuthString(client, buffer, sizeof(buffer));
	if (RemoveFromTrie(casterTrie, buffer))
	{
		casterCount--;
	}
}

public Native_AddStringToReadyFooter(Handle:plugin, numParams)
{
	decl String:footer[MAX_FOOTER_LEN];
	GetNativeString(1, footer, sizeof(footer));
	if (footerCounter < MAX_FOOTER_LEN)
	{
		if (strlen(footer) < MAX_FOOTER_LEN)
		{
			strcopy(readyFooter[footerCounter], MAX_FOOTER_LEN, footer);
			footerCounter++;
			return _:true;
		}
	}
	return _:false;
}

public Native_IsInReady(Handle:plugin, numParams)
{
	return _:inReadyUp;
}

public Action:Caster_Cmd(client, args)
{
	decl String:buffer[64];
	GetCmdArg(1, buffer, sizeof(buffer));

	new target = FindTarget(client, buffer, true, false);
	if (target > 0 && GetClientAuthString(target, buffer, sizeof(buffer)))
	{
		SetTrieValue(casterTrie, buffer, 1);
		PrintToChat(client, "Registered %N as a caster", target);
	}
	else
	{
		PrintToChat(client, "Couldn't find Steam ID.  Check for typos and let the player get fully connected.");
	}
}

public Action:NotCasting_Cmd(client, args)
{
	decl String:buffer[64];
	GetClientAuthString(client, buffer, sizeof(buffer));
	RemoveFromTrie(casterTrie, buffer);
}

public Action:ForceStart_Cmd(client, args)
{
	InitiateLiveCountdown();
	return Plugin_Handled;
}

public Action:Ready_Cmd(client, args)
{
	if (inReadyUp)
	{
		isPlayerReady[client] = true;
		if (CheckFullReady())
			InitiateLiveCountdown();

		UpdatePanel();
	}

	return Plugin_Handled;
}

public Action:Unready_Cmd(client, args)
{
	if (inReadyUp)
	{
		isPlayerReady[client] = false;
		CancelFullReady();
		
		UpdatePanel();
	}

	return Plugin_Handled;
}

public Action:ToggleReady_Cmd(client, args)
{
	if (inReadyUp)
	{
		isPlayerReady[client] = !isPlayerReady[client];
		if (isPlayerReady[client] && CheckFullReady())
		{
			InitiateLiveCountdown();
		}
		else
		{
			CancelFullReady();
		}
	}

	UpdatePanel();

	return Plugin_Handled;
}

/* No need to do any other checks since it seems like this is required no matter what since the intros unfreezes players after the animation completes */
public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (inReadyUp)
	{
		if (IsClientInGame(client) && !IsFakeClient(client) && L4D2Team:GetClientTeam(client) == L4D2Team_Survivor && !(GetEntityMoveType(client) == MOVETYPE_NONE || GetEntityMoveType(client) == MOVETYPE_NOCLIP))
		{
			SetFrozen(client, true);
		}
	}
}

public RoundStart_Event(Handle:event, const String:name[], bool:dontBroadcast)
{
	InitiateReadyUp();
}

public Action:InitReady_Cmd(client, args)
{
	InitiateReadyUp();
	return Plugin_Handled;
}

public Action:InitLive_Cmd(client, args)
{
	InitiateLive();
	return Plugin_Handled;
}

public DummyHandler(Handle:menu, MenuAction:action, param1, param2) { }

public Action:MenuRefresh_Timer(Handle:timer)
{
	if (inReadyUp)
	{
		UpdatePanel();
		return Plugin_Continue;
	}
	return Plugin_Handled;
}

UpdatePanel()
{
	if (menuPanel != INVALID_HANDLE)
	{
		CloseHandle(menuPanel);
		menuPanel = INVALID_HANDLE;
	}

	new String:readyBuffer[800] = "";
	new String:unreadyBuffer[800] = "";
	new String:specBuffer[800] = "";
	new readyCount = 0;
	new unreadyCount = 0;
	new specCount = 0;

	menuPanel = CreatePanel();

	decl String:nameBuf[MAX_NAME_LENGTH+4];
	decl String:authBuffer[64];
	decl bool:caster;
	decl dummy;
	for (new client = 1; client <= MaxClients; client++)
	{
		if(IsClientInGame(client) && !IsFakeClient(client))
		{
			GetClientName(client, nameBuf, sizeof(nameBuf));
			GetClientAuthString(client, authBuffer, sizeof(authBuffer));
			caster = GetTrieValue(casterTrie, authBuffer, dummy);
			if (IsPlayer(client) || caster)
			{
				if (isPlayerReady[client])
				{
					if (!inLiveCountdown) PrintHintText(client, "You are ready.\nSay !unready to unready.");
					Format(nameBuf, sizeof(nameBuf), "->%d. %s%s\n", ++readyCount, nameBuf, caster ? " [Caster]" : "");
					StrCat(readyBuffer, sizeof(readyBuffer), nameBuf);
				}
				else
				{
					if (!inLiveCountdown) PrintHintText(client, "You are not ready.\nSay !ready to ready up.");
					Format(nameBuf, sizeof(nameBuf), "->%d. %s%s\n", ++unreadyCount, nameBuf, caster ? " [Caster]" : "");
					StrCat(unreadyBuffer, sizeof(unreadyBuffer), nameBuf);
				}
			}
			else
			{
				Format(nameBuf, sizeof(nameBuf), "->%d. %s\n", ++specCount, nameBuf);
				StrCat(specBuffer, sizeof(specBuffer), nameBuf);
			}
		}
	}

	new bufLen = strlen(readyBuffer);
	if (bufLen != 0)
	{
		readyBuffer[bufLen] = '\0';
		ReplaceString(readyBuffer, sizeof(readyBuffer), "#buy", "<- TROLL");
		ReplaceString(readyBuffer, sizeof(readyBuffer), "#", "_");
		DrawPanelText(menuPanel, "Ready");
		DrawPanelText(menuPanel, readyBuffer);
	}

	bufLen = strlen(unreadyBuffer);
	if (bufLen != 0)
	{
		unreadyBuffer[bufLen] = '\0';
		ReplaceString(readyBuffer, sizeof(readyBuffer), "#buy", "<- TROLL");
		ReplaceString(unreadyBuffer, sizeof(unreadyBuffer), "#", "_");
		DrawPanelText(menuPanel, "Unready");
		DrawPanelText(menuPanel, unreadyBuffer);
	}

	bufLen = strlen(specBuffer);
	if (bufLen != 0)
	{
		specBuffer[bufLen] = '\0';
		ReplaceString(specBuffer, sizeof(specBuffer), "#", "_");
		DrawPanelText(menuPanel, "Spectator");
		DrawPanelText(menuPanel, specBuffer);
	}

	decl String:cfgBuf[128];
	GetConVarString(l4d_ready_server_cfg, cfgBuf, sizeof(cfgBuf));
	ReplaceString(cfgBuf, sizeof(cfgBuf), "#", "_");
	DrawPanelText(menuPanel, cfgBuf);

	for (new i = 0; i < MAX_FOOTERS; i++)
	{
		DrawPanelText(menuPanel, readyFooter[i]);
	}

	for (new client = 1; client <= MaxClients; client++)
	{
		if(IsClientInGame(client) && !IsFakeClient(client))
		{
			SendPanelToClient(menuPanel, client, DummyHandler, 1);
		}
	}
}

InitiateReadyUp()
{
	for (new i = 0; i <= MAXPLAYERS; i++)
	{
		isPlayerReady[i] = false;
	}

	UpdatePanel();
	CreateTimer(1.0, MenuRefresh_Timer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);

	inReadyUp = true;
	inLiveCountdown = false;
	readyCountdownTimer = INVALID_HANDLE;

	z_common_limit_initial = GetConVarInt(z_common_limit);
	z_ghost_delay_max_initial = GetConVarInt(z_ghost_delay_max);
	z_ghost_delay_min_initial = GetConVarInt(z_ghost_delay_min);

	SetConVarBool(director_no_mobs, true);
	if (GetConVarBool(l4d_ready_disable_spawns))
	{
		SetConVarBool(director_no_specials, true);
	}

	SetConVarFlags(god, GetConVarFlags(god) - FCVAR_NOTIFY);
	SetConVarBool(god, true);
	SetConVarFlags(god, GetConVarFlags(god) | FCVAR_NOTIFY);
	SetConVarBool(sb_stop, true);
	SetConVarInt(z_common_limit, 0);
	SetConVarInt(z_ghost_delay_max, 0);
	SetConVarInt(z_ghost_delay_min, 0);

	L4D2_CTimerStart(L4D2CT_VersusStartTimer, 99999.9);
}

InitiateLive()
{
	inReadyUp = false;
	inLiveCountdown = false;
	/*if (readyCountdownTimer != INVALID_HANDLE)*/
	/*{*/
		/*CloseHandle(readyCountdownTimer);*/
		/*readyCountdownTimer = INVALID_HANDLE;*/
	/*}*/

	SetConVarBool(director_no_mobs, false);
	SetConVarBool(director_no_specials, false);
	SetConVarFlags(god, GetConVarFlags(god) - FCVAR_NOTIFY);
	SetConVarBool(god, false);
	SetConVarFlags(god, GetConVarFlags(god) | FCVAR_NOTIFY);
	SetConVarBool(sb_stop, false);
	SetConVarInt(z_common_limit, z_common_limit_initial);
	SetConVarInt(z_ghost_delay_max, z_ghost_delay_max_initial);
	SetConVarInt(z_ghost_delay_min, z_ghost_delay_min_initial);

	L4D2_CTimerStart(L4D2CT_VersusStartTimer, 60.0);

	for (new client = 1; client <= MaxClients; client++)
	{
		if(IsClientInGame(client) && L4D2Team:GetClientTeam(client) == L4D2Team_Survivor)
		{
			SetFrozen(client, false);
		}
	}
	
	for (new i = 0; i < MAX_FOOTERS; i++)
	{
		readyFooter[i] = "";
	}
	Call_StartForward(liveForward);
	Call_Finish();
}

bool:CheckFullReady()
{
	decl String:authBuffer[64];
	decl bool:caster;
	decl dummy;
	new readyCount = 0;
	for (new client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			GetClientAuthString(client, authBuffer, sizeof(authBuffer));
			caster = GetTrieValue(casterTrie, authBuffer, dummy);
			if((IsPlayer(client) || caster) && isPlayerReady[client])
			{
				readyCount++;
			}
		}
	}
	return readyCount >= GetConVarInt(survivor_limit) + GetConVarInt(z_max_player_zombies) + casterCount;
}

InitiateLiveCountdown()
{
	if (readyCountdownTimer == INVALID_HANDLE)
	{
		PrintHintTextToAll("Going live!\nSay !unready to cancel");
		inLiveCountdown = true;
		readyDelay = 5;
		readyCountdownTimer = CreateTimer(1.0, ReadyCountdownDelay_Timer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action:ReadyCountdownDelay_Timer(Handle:timer)
{
	if (readyDelay == 0)
	{
		PrintHintTextToAll("Round is live!");
		InitiateLive();
		return Plugin_Stop;
	}
	else
	{
		PrintHintTextToAll("Live in: %d\nSay !unready to cancel", readyDelay);
		readyDelay--;
	}
	return Plugin_Continue;
}

CancelFullReady()
{
	if (readyCountdownTimer != INVALID_HANDLE)
	{
		inLiveCountdown = false;
		CloseHandle(readyCountdownTimer);
		readyCountdownTimer = INVALID_HANDLE;
		PrintHintTextToAll("Countdown Cancelled!");
	}
}

stock SetFrozen(client, freeze)
{
	SetEntityMoveType(client, freeze ? MOVETYPE_NONE : MOVETYPE_WALK);
}

stock IsPlayer(client)
{
	new L4D2Team:team = L4D2Team:GetClientTeam(client);
	return (team == L4D2Team_Survivor || team == L4D2Team_Infected);
}
