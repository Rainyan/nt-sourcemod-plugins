#pragma semicolon 1

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION	"1.1.0_test"

// NT maxplayers is guaranteed smaller than engine max (64),
// so we can allocate less memory by using this.
#define NEO_MAXPLAYERS 32

#define SONG_COUNT 15

#define RADIO_TAG "[radio]"
#define DEFAULT_RADIO_VOLUME 0.2

#define MAX_FANCY_STRLEN 44 // longest string GetSongMetadata can reasonably produce + '\0'

new const String:Playlist[SONG_COUNT][] = {
	"../soundtrack/101 - annul.mp3",
	"../soundtrack/102 - tinsoldiers.mp3",
	"../soundtrack/103 - beacon.mp3",
	"../soundtrack/104 - imbrium.mp3",
	"../soundtrack/105 - automata.mp3",
	"../soundtrack/106 - hiroden 651.mp3",
	"../soundtrack/109 - mechanism.mp3",
	"../soundtrack/110 - paperhouse.mp3",
	"../soundtrack/111 - footprint.mp3",
	"../soundtrack/112 - out.mp3",
	"../soundtrack/202 - scrap.mp3",
	"../soundtrack/207 - carapace.mp3",
	"../soundtrack/208 - stopgap.mp3",
	"../soundtrack/209 - radius.mp3",
	"../soundtrack/210 - rebuild.mp3"
};

bool RadioEnabled[NEO_MAXPLAYERS+1];
int SongEndEpoch[NEO_MAXPLAYERS+1];
int LastPlayedSong[NEO_MAXPLAYERS+1];
bool SdkPlayPrepared = false;

float RadioVolume[NEO_MAXPLAYERS+1];

ConVar UseSdkPlayback = null;

public Plugin myinfo =
{
    name = "NEOTOKYO° Radio",
    author = "Soft as HELL",
    description = "Play original soundtrack in game",
    version = PLUGIN_VERSION,
    url = "https://github.com/softashell/nt-sourcemod-plugins"
};

public void OnPluginStart()
{
	CreateConVar("sm_ntradio_version", PLUGIN_VERSION, "NEOTOKYO° Radio Version", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);
	
	HookEvent("game_round_start", Event_RoundStart, EventHookMode_Post);
	
	RegConsoleCmd("sm_radio", 	 Cmd_Radio);
	RegConsoleCmd("sm_radiooff", Cmd_Radio);
	
	RegConsoleCmd("sm_radiovol", Cmd_RadioVolume);
	RegConsoleCmd("sm_radiovolume", Cmd_RadioVolume);
	
	RegConsoleCmd("sm_radioskip", Cmd_RadioSkip);
	
	// More generic command aliases -- comment away if they clash with something on your server
	RegConsoleCmd("sm_vol", Cmd_RadioVolume);
	RegConsoleCmd("sm_volume", Cmd_RadioVolume);
	RegConsoleCmd("sm_skip", Cmd_RadioSkip);
	
	UseSdkPlayback = CreateConVar("sm_radio_type", "1", "Whether to use the old console \"play ...\" style (value 0), or new SDK tools play style with volume control (value 1).", _, true, 0.0, true, 1.0);
	HookConVarChange(UseSdkPlayback, PlayType_CvarChanged);
	
	if (UseSdkPlayback.BoolValue) {
		PrepareSdkPlaySounds();
	}
	
	ResetState();
	
	CreateTimer(5.0, Timer_NextSong, _, TIMER_REPEAT);
}

public void OnMapChange()
{
	SdkPlayPrepared = false;
	if (UseSdkPlayback.BoolValue) {
		PrepareSdkPlaySounds();
	}
}

public void PlayType_CvarChanged(ConVar convar, const char[] oldVal, const char[] newVal)
{
	if (convar.BoolValue && !SdkPlayPrepared) {
		PrepareSdkPlaySounds();
	}
	
	for (int client = 1; client <= MaxClients; ++client) {
		if (IsValidClient(client)) {
			// Force stop any songs since we've lost track when switching modes
			ClientCommand(client, "play common/null.wav");
			for (int song = 0; song < SONG_COUNT; ++song) {
				StopSound(client, SNDCHAN_AUTO, Playlist[song]);
			}
		}
	}
	
	ResetState();
}

void PrepareSdkPlaySounds()
{	
	for (int i = 0; i < SONG_COUNT; ++i) {
		PrecacheSound(Playlist[i]);
	}
	SdkPlayPrepared = true;
}

void ResetState()
{
	for (int client = 0; client < NEO_MAXPLAYERS; ++client) {
		RadioEnabled[client] = false;
		SongEndEpoch[client] = 0;
		LastPlayedSong[client] = 0;
		RadioVolume[client] = DEFAULT_RADIO_VOLUME;
	}
}

public void OnClientPutInServer(int client)
{
	RadioEnabled[client] = false;
	SongEndEpoch[client] = 0;
	LastPlayedSong[client] = 0;
	RadioVolume[client] = DEFAULT_RADIO_VOLUME;
}

public void OnClientDisconnect(int client)
{
	RadioEnabled[client] = false;
	SongEndEpoch[client] = 0;
	LastPlayedSong[client] = 0;
	RadioVolume[client] = DEFAULT_RADIO_VOLUME;
}

void Play(int client, bool playLastSong = false, float playFromPosition = 0.0, bool verbose = true)
{
	if(!IsValidClient(client))
		return;
	
	if (verbose) {
		if (!UseSdkPlayback.BoolValue || LastPlayedSong[client] == 0) {
			PrintToChat(client, "%s You are now listening to NEOTOKYO° radio. Type !radio again to turn it off.", RADIO_TAG);
			
			if (UseSdkPlayback.BoolValue) {
				PrintToChat(client, "%s !radiovol 0-100 to change volume. !radioskip to skip a song.", RADIO_TAG);
			}
		}
	}
	
	int Song = GetRandomInt(0, SONG_COUNT-1);
	
	if (UseSdkPlayback.BoolValue) {
		// Is a previous song still playing?
		if (GetTime() < SongEndEpoch[client]) {
			// Don't reset if we're looking to play the same song.
			Stop(client, !playLastSong);
		}
		
		if (playLastSong) {
			Song = LastPlayedSong[client];
		} else if (Song == LastPlayedSong[client]) {
			// Don't pick the same random song twice in a row.
			Song = (Song + 1) % SONG_COUNT;
		}
		
		EmitSoundToClient(client, Playlist[Song], _, _, _, _,
			RadioVolume[client], _, _, _, _, _, playFromPosition);
		
		SongEndEpoch[client] = Max(0, GetSongEndEpoch(Song) - RoundToCeil(playFromPosition));
		
		LastPlayedSong[client] = Song;
	} else {
		ClientCommand(client, "play \"%s\"", Playlist[Song]);
	}
	
	if (verbose) {
		// The timer callback is responsible for freeing this memory.
		DataPack data = CreateDataPack();
		data.WriteCell(GetClientUserId(client));
		data.WriteCell(Song);
		// Delay verbose song info to avoid a hard to read wall of text in chat.
		CreateTimer(3.0 , Timer_ShowSongDetails, data);
	}
	
	if (RadioVolume[client] == 0) {
		PrintToChat(client, "%s Your radio is muted. Type !radiovol to change volume.", RADIO_TAG);
	}
}

public Action Timer_ShowSongDetails(Handle timer, DataPack data)
{
	data.Reset();
	int client = GetClientOfUserId(data.ReadCell());
	
	if (IsValidClient(client) && RadioEnabled[client]) {
		int song = data.ReadCell();
		
		decl String:songFancyName[MAX_FANCY_STRLEN];
		GetSongMetadata(song, songFancyName, MAX_FANCY_STRLEN);
		
		PrintToChat(client, "%s Now playing: %s", RADIO_TAG, songFancyName);
	}
	
	delete data;
	
	return Plugin_Stop;
}

public Action Timer_NextSong(Handle timer)
{
	if (UseSdkPlayback.BoolValue) {
		int timeNow = GetTime();
		
		for (int client = 1; client <= MaxClients; ++client) {
			if (RadioEnabled[client] && timeNow > SongEndEpoch[client]) {
				Play(client);
			}
		}
	}
	
	return Plugin_Continue;
}

void Stop(int client, bool resetLastPlayedSong = true) {
	if (IsValidClient(client)) {
		if (UseSdkPlayback.BoolValue) {
			StopSound(client, SNDCHAN_AUTO, Playlist[LastPlayedSong[client]]);
			SongEndEpoch[client] = 0;
			
			if (resetLastPlayedSong) {
				LastPlayedSong[client] = 0;
			}
		} else {
			ClientCommand(client, "play common/null.wav");
		}
	}
}

public Action Cmd_Radio(int client, int args)
{
	RadioEnabled[client] = !RadioEnabled[client];
		
	if(RadioEnabled[client])
	{
		if (!UseSdkPlayback.BoolValue || GetTime() > SongEndEpoch[client]) {
			Play(client);
		}
	}
	else {
		Stop(client);
	}
	
	return Plugin_Handled;
}

public Action Cmd_RadioVolume(int client, int args)
{
	if (!UseSdkPlayback.BoolValue) {
		ReplyToCommand(client, "%s This server uses a radio mode that doesn't support volume adjust.", RADIO_TAG);
		return Plugin_Handled;
	}
	
	if (args != 1) {
		ReplyToCommand(client, "%s Usage: sm_radiovol <value in range 0-100>", RADIO_TAG);
		return Plugin_Handled;
	}
	
	decl String:buffer[4];
	if (GetCmdArg(1, buffer, sizeof(buffer)) < 1) {
		ReplyToCommand(client, "%s Failed to parse volume. Usage: sm_radiovol <value in range 0-100>", RADIO_TAG);
		return Plugin_Handled;
	}
	
	// Representing volume to client as 0-100 integer for intuitivity, but engine internally uses a float of 0.0-1.0.
	int intVolume = Min(100, Max(0, StringToInt(buffer)));
	RadioVolume[client] = intVolume / 100.0;
	
	ReplyToCommand(client, "%s Your radio volume level is now %i\%.", RADIO_TAG, intVolume);
	
	if (RadioEnabled[client]) {
		Play(client, true, 1.0 * Max(0, SongEndEpoch[client] - GetTime()), false);	
	}
	
	return Plugin_Handled;
}

public Action Cmd_RadioSkip(int client, int args)
{
	if (!RadioEnabled[client]) {
		Cmd_Radio(client, args);
	} else {
		ReplyToCommand(client, "%s Skipping song.", RADIO_TAG);
		Play(client);
	}
	
	return Plugin_Handled;
}

public Action Event_RoundStart(Handle event, const char[] name, bool dontBroadcast){
	if (UseSdkPlayback.BoolValue) {
		int timeNow = GetTime();
		for(int client = 1; client <= MaxClients; ++client) {
			if(RadioEnabled[client]) {
				Play(client, true, 1.0 * Max(0, SongEndEpoch[client] - timeNow));
			}
		}
	} else {
		for(int client = 1; client <= MaxClients; ++client) {
			if(RadioEnabled[client]) {
				Play(client);
			}
		}
	}
	
	return Plugin_Continue;
}

bool IsValidClient(client){
	if (client == 0)
		return false;
	
	if (!IsClientConnected(client))
		return false;
	
	if (IsFakeClient(client))
		return false;
	
	if (!IsClientInGame(client))
		return false;
	
	return true;
}

int GetSongEndEpoch(int songIndex)
{
	if (songIndex < 0 || songIndex >= SONG_COUNT)
		ThrowError("Invalid song index %i", songIndex);
	
	// Minutes, seconds, and 1 extra second to make sure the songs have time to fully finish.
	int songLengthsInSeconds[SONG_COUNT] = {
		(6 * 60 + 34 + 1),	// 101 - annul.mp3
		(8 * 60 + 13 + 1),	// 102 - tinsoldiers.mp3
		(6 * 60 + 50 + 1),	// 103 - beacon.mp3
		(4 * 60 + 48 + 1),	// 104 - imbrium.mp3
		(6 * 60 + 02 + 1),	// 105 - automata.mp3
		(5 * 60 + 46 + 1),	// 106 - hiroden 651.mp3
		(5 * 60 + 56 + 1),	// 109 - mechanism.mp3
		(5 * 60 + 53 + 1),	// 110 - paperhouse.mp3
		(6 * 60 + 04 + 1),	// 111 - footprint.mp3
		(8 * 60 + 17 + 1),	// 112 - out.mp3
		(5 * 60 + 41 + 1),	// 202 - scrap.mp3
		(5 * 60 + 17 + 1),	// 207 - carapace.mp3
		(6 * 60 + 12 + 1),	// 208 - stopgap.mp3
		(3 * 60 + 56 + 1),	// 209 - radius.mp3
		(5 * 60 + 11 + 1)	// 210 - rebuild.mp3
	};
	
	return GetTime() + songLengthsInSeconds[songIndex];
}

void GetSongMetadata(int songIndex, char[] outString, int outSize)
{
	if (songIndex < 0 || songIndex >= SONG_COUNT) {
		ThrowError("Invalid song index");
	} else if (outSize < 1) {
		ThrowError("Invalid out size");
	}
	
	new const String:songTitles[SONG_COUNT][] = {
		"Annul",
		"Tin Soldiers",
		"Beacon",
		"Imbrium",
		"Automata",
		"Hiroden 651",
		"Mechanism",
		"Paperhouse",
		"Footprint",
		"Out",
		"Scrap I/O",
		"Carapace",
		"Stopgap",
		"Radius",
		"Rebuild"
	};
	
	new const String:albumInfo[] = "Ed Harrison (Neotokyo OST)";
	
	if (Format(outString, outSize, "%s – %s", songTitles[songIndex], albumInfo) < 1) {
		ThrowError("String format failed"); // throw so we never pass unallocated memory
	}
}

int Min(int v1, int v2)
{
	if (v1 < v2)
		return v1;
	else
		return v2;
}

int Max(int v1, int v2)
{
	if (v1 > v2)
		return v1;
	else
		return v2;
}