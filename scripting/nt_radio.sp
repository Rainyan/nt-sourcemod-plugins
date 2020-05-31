#pragma semicolon 1

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION	"1.1.1"

// NT maxplayers is guaranteed smaller than engine max (64),
// so we can allocate less memory by using this.
#define NEO_MAXPLAYERS 32

#define SONG_COUNT 15

#define RADIO_TAG "[radio]"
#define DEFAULT_RADIO_VOLUME 0.2

#define MAX_FANCY_STRLEN 44 // longest string GetSongMetadata can reasonably produce + '\0'
#define SAMPLE_RATE_HZ 44100

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
float SongEndEpoch[NEO_MAXPLAYERS+1];
int LastPlayedSong[NEO_MAXPLAYERS+1];
bool SdkPlayPrepared = false;

float RadioVolume[NEO_MAXPLAYERS+1];

ConVar UseSdkPlayback = null;
ConVar ShowDebug = null;

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
	
	ShowDebug = CreateConVar("sm_radio_debug", "0", "Whether to show debug info on playback.", _, true, 0.0, true, 1.0);
	
	
	if (UseSdkPlayback.BoolValue) {
		PrepareSdkPlaySounds();
	}
	
	ResetState();
	
	CreateTimer(5.0, Timer_NextSong, _, TIMER_REPEAT);
	
	AutoExecConfig(true);
}

public void OnMapStart()
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
		SongEndEpoch[client] = 0.0;
		LastPlayedSong[client] = 0;
		RadioVolume[client] = DEFAULT_RADIO_VOLUME;
	}
}

public void OnClientPutInServer(int client)
{
	RadioEnabled[client] = false;
	SongEndEpoch[client] = 0.0;
	LastPlayedSong[client] = 0;
	RadioVolume[client] = DEFAULT_RADIO_VOLUME;
}

public void OnClientDisconnect(int client)
{
	RadioEnabled[client] = false;
	SongEndEpoch[client] = 0.0;
	LastPlayedSong[client] = 0;
	RadioVolume[client] = DEFAULT_RADIO_VOLUME;
}

void Play(int client, bool playLastSong = false, float playFromPosition = 0.0, bool verbose = true)
{
	if(!IsValidClient(client))
		return;

	// It's broken on the engine, just turn this always off for now...
	playFromPosition = 0.0;
	
	float secs = playFromPosition / SAMPLE_RATE_HZ;
	
	PrintDebug(client, "Playing from pos: %.3f secs (%.3f samples). Playlast: %s",
		playFromPosition / SAMPLE_RATE_HZ,
		playFromPosition,
		(playLastSong ? "yes" : "no"));
	
	if (verbose) {
		if (!UseSdkPlayback.BoolValue || LastPlayedSong[client] == 0) {
			ReplyToCommand(client, "%s You are now listening to NEOTOKYO° radio. Type !radio again to turn it off.", RADIO_TAG);
			
			if (UseSdkPlayback.BoolValue) {
				ReplyToCommand(client, "%s !radiovol 0-100 to change volume. !radioskip to skip a song.",
					RADIO_TAG);
			}
		}
	}
	
	int Song = GetRandomInt(0, SONG_COUNT-1);
	
	if (UseSdkPlayback.BoolValue) {
		// Just in case, always stop any previous song.
		// Don't reset last song if we're looking to play the same song.
		Stop(client, !playLastSong);
		
		if (playLastSong) {
			Song = LastPlayedSong[client];
		} else if (Song == LastPlayedSong[client]) {
			// Don't pick the same random song twice in a row.
			Song = (Song + 1) % SONG_COUNT;
		}
		
		EmitSoundToClient(client, Playlist[Song], _, _, _, _, RadioVolume[client],
			_, _, _, _, _, secs);
		
		PrintDebug(client, "SECONDS: %f", secs);
		
		PrintDebug(client, "SongEndEpoch[client] pre = %.3f", SongEndEpoch[client]);
		
		SongEndEpoch[client] = FMax(0.0, GetSongEndEpoch(Song) - playFromPosition / SAMPLE_RATE_HZ);
		
		PrintDebug(client, "SongEndEpoch[client] post = %.3f", SongEndEpoch[client]);
		PrintDebug(client, "GetSongEpoch: %.3f", GetSongEndEpoch(Song));
		PrintDebug(client, "RoundToCeil(playFromPosition): %.3f",
			RoundToCeil(playFromPosition / SAMPLE_RATE_HZ));
		
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
		ReplyToCommand(client, "%s Your radio is muted. Type !radiovol to change volume.", RADIO_TAG);
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
		float timeNow = GetGameTime();
		
		for (int client = 1; client <= MaxClients; ++client) {
			if (RadioEnabled[client] && timeNow > SongEndEpoch[client]) {
				
				if (IsValidClient(client)) {
					PrintDebug(client, "Playing next song now! (epoch: %.3f > future: %.3f)", timeNow, SongEndEpoch[client]);
				}

				Play(client);
			} else if (RadioEnabled[client]) {
				PrintDebug(client, "delta time until next song: %.3f seconds (epoch %.3f vs future: %.3f)",
					SongEndEpoch[client] - timeNow, timeNow, SongEndEpoch[client]);
			}
		}
	}
	
	return Plugin_Continue;
}

void Stop(int client, bool resetLastPlayedSong = true) {
	if (IsValidClient(client)) {
		if (UseSdkPlayback.BoolValue) {
			for (int song = 0; song < SONG_COUNT; ++song) {
				StopSound(client, SNDCHAN_AUTO, Playlist[song]);
			}
			
			if (resetLastPlayedSong) {
				LastPlayedSong[client] = 0;
			}
			
			SongEndEpoch[client] = 0.0;
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
		if (!UseSdkPlayback.BoolValue || GetGameTime() > SongEndEpoch[client]) {
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
		ReplyToCommand(client, "%s Your volume level is %i%c. Usage: sm_radiovol <value in range 0-100>", RADIO_TAG, RoundToNearest(RadioVolume[client] * 100), '%');
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
	
	ReplyToCommand(client, "%s Your radio volume level is now %i%c.", RADIO_TAG, intVolume, '%');
	
	if (RadioEnabled[client]) {
		PrintDebug(client, "VOLUME SongEndE: %.3f minus GetGameTime %.3f == %.3f",
			SongEndEpoch[client],
			GetGameTime(),
			SongEndEpoch[client] - GetGameTime());
		
		Stop(client, false);
		Play(client, true, FMax(0.0, SongEndEpoch[client] - GetGameTime()), false);
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
		float timeNow = GetGameTime();
		for(int client = 1; client <= MaxClients; ++client) {
			if(RadioEnabled[client]) {
				
				float songEndDelta = SongEndEpoch[client] - timeNow;
				float songLength = GetSongLength(LastPlayedSong[client]);
				// Magic number hack since it seems we undershoot slightly for some reason.
				float futureSeek = 0.0;
				float resumePoint = FMax(0.0, (songLength - songEndDelta + futureSeek) * SAMPLE_RATE_HZ);
				// Don't seek past the song end point.
				resumePoint = FMin(resumePoint, (songLength) * SAMPLE_RATE_HZ);
				
				PrintDebug(client, "RoundStart SongEndE: %.3f minus timeNow %.3f - 1 == %.3f, and song(%i) length %.3f - that is %.3f",
					SongEndEpoch[client],
					timeNow,
					SongEndEpoch[client] - timeNow - 1,
					
					LastPlayedSong[client],
					GetSongLength(LastPlayedSong[client]),
					GetSongLength(LastPlayedSong[client]) - SongEndEpoch[client] - timeNow - 1);
				
				PrintDebug(client, "songEndDelta: %.3f, songLength: %.3f", songEndDelta, songLength);
				PrintDebug(client, "songLength - songEndDelta == %.3f", songLength - songEndDelta);
				
				//int playFrom = GetSongLength(LastPlayedSong[client]) - SongEndEpoch[client] - timeNow - 1;
				
				PrintDebug(client, "RESUME POINT: %.3f secs (%.3f samples) of %.3f secs (%.3f samples) total",
					resumePoint / SAMPLE_RATE_HZ,
					resumePoint,
					songLength,
					songLength * SAMPLE_RATE_HZ);
				Play(client, true, resumePoint);
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

float GetSongLength(int songIndex)
{
	if (songIndex < 0 || songIndex >= SONG_COUNT)
		ThrowError("Invalid song index %i", songIndex);
	
	// Exact song lengths up to 3 decimal points.
	// Need the accuracy because Source audio seek wants an exact
	// sample location, ie. length in seconds * sample rate.
	float songLengthsInSeconds[SONG_COUNT] = {
		394.055, // 101 - annul.mp3
		493.006, // 102 - tinsoldiers.mp3
		410.162, // 103 - beacon.mp3
		288.627, // 104 - imbrium.mp3
		362.252, // 105 - automata.mp3
		346.577, // 106 - hiroden 651.mp3
		356.572, // 109 - mechanism.mp3
		353.693, // 110 - paperhouse.mp3
		364.796, // 111 - footprint.mp3
		497.754, // 112 - out.mp3
		340.984, // 202 - scrap.mp3
		317.362, // 207 - carapace.mp3
		372.961, // 208 - stopgap.mp3
		236.413, // 209 - radius.mp3
		311.425, // 210 - rebuild.mp3
	};
	
	PrintToServer("Song at index %i is %.3f seconds", songIndex, songLengthsInSeconds[songIndex]);
	
	return songLengthsInSeconds[songIndex];
}

float GetSongEndEpoch(int songIndex)
{
	float time = GetGameTime();
	float len = GetSongLength(songIndex);
	
	PrintToServer("Returning time %.3f + len %.3f == %.3f", time, len, time + len);
	
	return time + len;
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

float FMin(float v1, float v2)
{
	if (v1 < v2)
		return v1;
	else
		return v2;
}

float FMax(float v1, float v2)
{
	if (v1 > v2)
		return v1;
	else
		return v2;
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

void PrintDebug(int caller, const char[] msg, any ...)
{
	if (!ShowDebug.BoolValue) {
		return;
	}
	decl String:buffer[1024];
	int bytes = VFormat(buffer, sizeof(buffer), msg, 3);
	if (bytes <= 0) {
		ThrowError("VFormat failed on: %s", msg);
	}
	
	PrintToServer(buffer);
	PrintToChat(caller, buffer);
	PrintToConsole(caller, buffer);
}