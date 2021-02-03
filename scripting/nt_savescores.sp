#include <sourcemod>
#include <neotokyo>

#pragma semicolon 1
#pragma newdecls required

#define MAX_STEAMID_LEN 30

#define NEO_MAX_PLAYERS 32

public Plugin myinfo =
{
	name = "NEOTOKYO° Temporary score saver",
	author = "soft as HELL",
	description = "Saves score when player disconnects and restores it if player connects back before map change",
	version = "0.6.1",
	url = "https://github.com/softashell/nt-sourcemod-plugins"
};

Database hDB = null;
Handle hRestartGame, hResetScoresTimer, hScoreDatabase;
bool bScoreLoaded[NEO_MAX_PLAYERS+1],bResetScores, g_bHasJoinedATeam[NEO_MAX_PLAYERS+1];

public void OnPluginStart()
{
	hScoreDatabase = CreateConVar("nt_savescore_database_config", "storage-local", "Database config used for saving scores", FCVAR_PROTECTED);

	hRestartGame = FindConVar("neo_restart_this");

	// Hook restart command
	if(hRestartGame != INVALID_HANDLE)
	{
		HookConVarChange(hRestartGame, RestartGame);
	}

	AddCommandListener(cmd_JoinTeam, "jointeam");

	HookEvent("game_round_start", event_RoundStart);

	bResetScores = false;
}

public void OnConfigsExecuted()
{
	// Create new database if it doesn't exist
	DB_init();

	// Clear it if we're reloading plugin or just started it
	DB_clear();

	bResetScores = false;
}

public void RestartGame(Handle convar, const char[] oldValue, const char[] newValue)
{
	if(StringToInt(newValue) == 0)
		return; // Not restarting

	if(hResetScoresTimer != INVALID_HANDLE)
		CloseHandle(hResetScoresTimer);

	float fTimer = StringToFloat(newValue);

	hResetScoresTimer = CreateTimer(fTimer - 0.1, ResetScoresNextRound);
}

public Action ResetScoresNextRound(Handle timer)
{
	bResetScores = true;

	hResetScoresTimer = INVALID_HANDLE;
}

public void OnClientPutInServer(int client)
{
	g_bHasJoinedATeam[client] = false;
}

public void OnClientDisconnect(int client)
{
	if(!bScoreLoaded[client] && !g_bHasJoinedATeam[client])
		return; // Never tried to load score

	DB_insertScore(client);

	bScoreLoaded[client] = false;
}

public Action cmd_JoinTeam(int client, const char[] command, int argc)
{
	char cmd[3];
	GetCmdArgString(cmd, sizeof(cmd));

	if(!IsValidClient(client))
		return;

	if(IsPlayerAlive(client))
		return; // Alive player switching team, should never happen when you just connect

	int team_current = GetClientTeam(client);
	int team_target = StringToInt(cmd);

	if(team_current == team_target && team_target != 0 && team_current != 0)
		return; // Trying to join same team

	// Score isn't loaded from DB yet
	if(!bScoreLoaded[client])
		DB_retrieveScore(client);

	g_bHasJoinedATeam[client] = true;
}

public Action event_RoundStart(Handle event, const char[] name, bool dontBroadcast)
{
	if(!bResetScores)
		return;

	bResetScores = false;

	DB_clear();
}

void DB_init()
{
	if (hDB != null)
		return;

	char score_database_filename[PLATFORM_MAX_PATH];
	GetConVarString(hScoreDatabase, score_database_filename, sizeof(score_database_filename));

	Database.Connect(Cb_GotDatabase, score_database_filename);
}

public void Cb_GotDatabase(Database db, const char[] error, any data)
{
	if (db == null)
		SetFailState("Database connection error: %s", error);

	hDB = db;

	hDB.Query(DBCb_fireAndForget, "CREATE TABLE IF NOT EXISTS nt_saved_score (steamID TEXT PRIMARY KEY, xp SMALLINT, deaths SMALLINT);");
}

void DB_clear()
{
	if (hDB != null)
		hDB.Query(DBCb_fireAndForget, "DELETE FROM nt_saved_score;");
}

void DB_insertScore(int client)
{
	if (hDB == null)
		return;

	if(!IsValidClient(client))
		return;

	char steamID[MAX_STEAMID_LEN], query[64 + MAX_STEAMID_LEN];
	int xp, deaths;

	GetClientAuthId(client, AuthId_SteamID64, steamID, sizeof(steamID));
	// Avoid injection in the off chance the client has spoofed their SteamID (hacked client, etc.)
	hDB.Escape(steamID, steamID, sizeof(steamID));

	xp = GetPlayerXP(client);
	deaths = GetPlayerDeaths(client);

	Format(query, sizeof(query), "INSERT OR REPLACE INTO nt_saved_score VALUES ('%s', %d, %d);", steamID, xp, deaths);

	hDB.Query(DBCb_fireAndForget, query);
}

void DB_deleteScore(int client)
{
	if (hDB == null)
		return;

	if(!IsValidClient(client))
		return;

	char steamID[MAX_STEAMID_LEN], query[47 + MAX_STEAMID_LEN];

	GetClientAuthId(client, AuthId_SteamID64, steamID, sizeof(steamID));
	// Avoid injection in the off chance the client has spoofed their SteamID (hacked client, etc.)
	hDB.Escape(steamID, steamID, sizeof(steamID));

	Format(query, sizeof(query), "DELETE FROM nt_saved_score WHERE steamID = '%s';", steamID);

	hDB.Query(DBCb_fireAndForget, query);
}

void DB_retrieveScore(int client)
{
	if (hDB == null)
		return;

	if(!IsValidClient(client))
		return;

	bScoreLoaded[client] = true; // At least we tried!

	char steamID[MAX_STEAMID_LEN], query[49 + MAX_STEAMID_LEN];

	GetClientAuthId(client, AuthId_SteamID64, steamID, sizeof(steamID));
	// Avoid injection in the off chance the client has spoofed their SteamID (hacked client, etc.)
	hDB.Escape(steamID, steamID, sizeof(steamID));

	Format(query, sizeof(query), "SELECT * FROM nt_saved_score WHERE steamID = '%s';", steamID);

	hDB.Query(DBCb_retrieveScoreCallback, query, GetClientUserId(client));
}

// Empty callback for when you don't care about the result, but still want to use a threaded query.
// Good replacement for the synchronous SQL_FastQuery when it could negatively affect server performance,
// for example during slow I/O.
public void DBCb_fireAndForget(Database db, DBResultSet results, const char[] error, any data)
{
}

public void DBCb_retrieveScoreCallback(Database db, DBResultSet results, const char[] error, int userid)
{
	if (results == null)
	{
		LogError("SQL Error: %s", error);
		return;
	}

	int client = GetClientOfUserId(userid);

	if(client == 0)
		return;

	if (results.RowCount == 0)
		return;

	int xp = results.FetchInt(1);
	int deaths = results.FetchInt(2);

	if(xp != 0 || deaths != 0)
	{
		SetPlayerXP(client, xp);
		SetPlayerDeaths(client, deaths);

		PrintToChat(client, "[NT°] Saved score restored!");
		PrintToConsole(client, "[NT°] Saved score restored! XP: %d Deaths: %d", xp, deaths);
	}

	// Remove score from DB after it has been loaded
	DB_deleteScore(client);
}
