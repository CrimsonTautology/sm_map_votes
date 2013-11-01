/**
 * vim: set ts=4 :
 * =============================================================================
 * map_votes
 * Interact with the Map Votes web api - https://github.com/CrimsonTautology/map_votes
 *
 * Copyright 2013 The Crimson Tautology
 * =============================================================================
 *
 */


#pragma semicolon 1

#include <sourcemod>
#include <socket>
#include <base64>

#undef REQUIRE_EXTENSIONS
#include <smjansson>

#define PLUGIN_VERSION "0.1"

public Plugin:myinfo = {
    name = "MapVotes",
    author = "CrimsonTautology",
    description = "Interact with the Map Votes web api",
    version = PLUGIN_VERSION,
    url = "https://github.com/CrimsonTautology/sm_map_votes"
};

#define CAST_VOTE_ROUTE "/v1/api/cast_vote"
#define WRITE_MESSAGE_ROUTE "/v1/api/write_message"
#define FAVORITE_ROUTE "/v1/api/favorite"
#define UNFAVORITE_ROUTE "/v1/api/unfavorite"
#define GET_FAVORITES_ROUTE "/v1/api/get_favorites"
#define HAVE_NOT_VOTED_ROUTE "/v1/api/have_not_voted"
#define SERVER_QUERY_ROUTE "/v1/api/server_query"
#define MAPS_ROUTE "/maps"

#define MAX_STEAMID_LENGTH 21 
#define MAX_COMMUNITYID_LENGTH 18 


new Handle:g_Cvar_MapVotesUrl = INVALID_HANDLE;
new Handle:g_Cvar_MapVotesPort = INVALID_HANDLE;
new Handle:g_Cvar_MapVotesApiKey = INVALID_HANDLE;
new Handle:g_Cvar_MapVotesVotingEnabled = INVALID_HANDLE;
new Handle:g_Cvar_MapVotesCommentingEnabled = INVALID_HANDLE;
new Handle:g_Cvar_MapVotesNominationsName = INVALID_HANDLE;

new g_MapFileSerial = -1;
new Handle:g_MapList = INVALID_HANDLE;
new Handle:g_MapTrie = INVALID_HANDLE;

new Handle:g_nominations = INVALID_HANDLE;
new Function:g_Handler_MapSelectMenu = INVALID_FUNCTION;

new bool:g_JanssonEnabled = false;


public OnPluginStart()
{

    g_Cvar_MapVotesUrl = CreateConVar("sm_map_votes_url", "", "URL to your Map Votes web page");
    g_Cvar_MapVotesPort = CreateConVar("sm_map_votes_port", "80", "HTTP Port used");
    g_Cvar_MapVotesApiKey = CreateConVar("sm_map_votes_api_key", "", "The API key you generated to interact with the Map Votes web page");
    g_Cvar_MapVotesVotingEnabled = CreateConVar("sm_map_votes_voting_enabled", "1", "Whether players are allowed to vote on the current map");
    g_Cvar_MapVotesCommentingEnabled = CreateConVar("sm_map_votes_commenting_enabled", "1", "Whether players are allowed to comment on the current map");
    g_Cvar_MapVotesNominationsName = CreateConVar("sm_map_votes_nominations_plugin", "nominations.smx", "The nominations plugin used by the server");

    RegConsoleCmd("sm_votemenu", Command_VoteMenu, "Bring up a menu to vote on the current map");
    RegConsoleCmd("sm_voteup", Command_VoteUp, "Vote that you like the current map");
    RegConsoleCmd("sm_like", Command_VoteUp, "Vote that you like the current map");
    RegConsoleCmd("sm_votedown", Command_VoteDown, "Vote that you hate the current map");
    RegConsoleCmd("sm_hate", Command_VoteDown, "Vote that you hate the current map");

    RegConsoleCmd("sm_fav", Command_Favorite, "Add this map to your favorites");
    RegConsoleCmd("sm_unfav", Command_Unfavorite, "Remove this map to your favorites");
    RegConsoleCmd("sm_nomfav", Command_GetFavorites, "Nominate from a list of your favorites");

    RegConsoleCmd("sm_mapcomment", Command_MapComment, "Comment on the current map");
    RegConsoleCmd("sm_mc", Command_MapComment, "Comment on the current map");

    RegConsoleCmd("sm_viewmap", Command_ViewMap, "View the Map Votes web page for this map");

    RegAdminCmd("sm_have_not_voted", Command_HaveNotVoted, ADMFLAG_VOTE, "Popup a vote panel to every player on the server that has not yet voted on this map");

    RegConsoleCmd("test", Test);

    new array_size = ByteCountToCells(PLATFORM_MAX_PATH);        
    g_MapList = CreateArray(array_size);
    g_MapTrie = CreateTrie();
}

public OnConfigsExecuted()
{
    BuildMapListAndTrie();
}

public OnAllPluginsLoaded() {
    if (LibraryExists("jansson")) {
        g_JanssonEnabled = true;
    }

    new noms = GetConVarString(g_Cvar_MapVotesUrl, base_url, sizeof(base_url));
    g_nominations = FindPluginByFile(noms);

    //Check if nominations.smx is both available and currently running
    if(g_nominations == INVALID_HANDLE || GetPluginStatus(g_nominations) != Plugin_Running){
        SetFailState("[MapVotes] Error, nominations is currently not running");
    }
    else{
        //We should be clear to link the MapSelectMenu function
        g_Handler_MapSelectMenu = GetFunctionByName(g_nominations, "Handler_MapSelectMenu");
    }
}

public OnLibraryAdded(const String:name[]) {
    if (StrEqual(name, "jansson")) {
        g_JanssonEnabled = true;
    }
}

public OnLibraryRemoved(const String:name[]) {
    if (StrEqual(name, "jansson")) {
        g_JanssonEnabled = false;
    }
}

public Action:Command_VoteMenu(client, args)
{
    if(client && IsClientAuthorized(client) && GetConVarBool(g_Cvar_MapVotesVotingEnabled)){
        CallVoteOnClient(client);
    }

    return Plugin_Handled;
}

public Action:Command_VoteUp(client, args)
{
    if(client && IsClientAuthorized(client) && GetConVarBool(g_Cvar_MapVotesVotingEnabled)){
        CastVote(client, 1);
    }

    return Plugin_Handled;
}

public Action:Command_VoteDown(client, args)
{
    if(client && IsClientAuthorized(client) && GetConVarBool(g_Cvar_MapVotesVotingEnabled)){
        CastVote(client, -1);
    }

    return Plugin_Handled;
}

public Action:Command_Favorite(client, args)
{
    if(client && IsClientAuthorized(client) && GetConVarBool(g_Cvar_MapVotesVotingEnabled)){
        new String:map[PLATFORM_MAX_PATH];
        if (args <= 0)
        {
            GetCurrentMap(map, sizeof(map));
            Favorite(map, client, true);
        }else{
            GetCmdArg(1, map, sizeof(map));
            MapSearch(client, map, g_MapList, FavoriteSearchHandler);
        }
    }

    return Plugin_Handled;
}
public Action:Command_Unfavorite(client, args)
{
    if(client && IsClientAuthorized(client) && GetConVarBool(g_Cvar_MapVotesVotingEnabled)){
        new String:map[PLATFORM_MAX_PATH];
        if (args <= 0)
        {
            GetCurrentMap(map, sizeof(map));
            Favorite(map, client, false);
        }else{
            GetCmdArg(1, map, sizeof(map));
            MapSearch(client, map, g_MapList, UnfavoriteSearchHandler);
        }

    }

    return Plugin_Handled;
}
public Action:Command_GetFavorites(client, args)
{
    if(client && IsClientAuthorized(client) && GetConVarBool(g_Cvar_MapVotesVotingEnabled)){
        GetFavorites(client);
    }

    return Plugin_Handled;
}

public Action:Command_ViewMap(client, args)
{
    if(client && IsClientAuthorized(client)){
        ViewMap(client);
    }

    return Plugin_Handled;
}

public Action:Command_MapComment(client, args)
{
    if (!GetConVarBool(g_Cvar_MapVotesCommentingEnabled))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[MapVotes] Usage: !map_comment <comment>");
        return Plugin_Handled;
    }

    if(client && IsClientAuthorized(client)){
        decl String:comment[256];
        GetCmdArgString(comment, sizeof(comment));
        WriteMessage(client, comment);
    }

    return Plugin_Handled;
}

public Action:Command_HaveNotVoted(client, args)
{
    HaveNotVoted();

    return Plugin_Handled;
}

public OnSocketConnected(Handle:socket, any:headers_pack)
{
    decl String:request_string[1024];

    ResetPack(headers_pack);
    ReadPackCell(headers_pack);
    ReadPackString(headers_pack, request_string, sizeof(request_string));

    SocketSend(socket, request_string);
}

public OnSocketReceive(Handle:socket, String:receive_data[], const data_size, any:headers_pack) {
    //Used for data received back
    if(g_JanssonEnabled)
    {
        //TODO parse JSON response
        //PrintToConsole(0,"%s", receive_data);//TODO

        new String:raw[2][1024], String:line[2][1024];
        ExplodeString(receive_data, "\r\n\r\n", raw, sizeof(raw), sizeof(raw[]));
        ExplodeString(raw[1], "\r\n", line, sizeof(line), sizeof(line[]));
        //PrintToConsole(0,"%s", line[1]);//TODO

        new Handle:json = json_load(line[1]);
        new String:command[1024];
        //TODO have way to handle missing value
        json_object_get_string(json, "command", command, sizeof(command));
        //PrintToConsole(0,"%s", command);//TODO


        //TODO have integer based commands
        if(strcmp(command, "have_not_voted") == 0){
            ParseHaveNotVoted(json);
        }else if(strcmp(command, "cast_vote") == 0){
        }else if(strcmp(command, "write_message") == 0){
        }else if(strcmp(command, "favorite") == 0){
        }else if(strcmp(command, "unfavorite") == 0){
        }

    } else
    {
        PrintToConsole(0,"Cannot parse JSON; SMJannson not installed");
    }
}

public OnSocketDisconnected(Handle:socket, any:headers_pack) {
    // Connection: close advises the webserver to close the connection when the transfer is finished
    // we're done here
    CloseHandle(headers_pack);
    CloseHandle(socket);
}

public OnSocketError(Handle:socket, const error_type, const error_num, any:headers_pack) {
    // a socket error occured
    ResetPack(headers_pack);
    decl client = GetClientOfUserId(ReadPackCell(headers_pack));

    if(error_type == EMPTY_HOST )
    {
        LogError("[MapVotes] Empty Host (errno %d)", error_num);
    } else if (error_type == NO_HOST )
    {
        LogError("[MapVotes] No Host (errno %d)", error_num);
    } else if (error_type == CONNECT_ERROR )
    {
        LogError("[MapVotes] Connection Error (errno %d)", error_num);
    } else if (error_type == SEND_ERROR )
    {
        LogError("[MapVotes] Send Error (errno %d)", error_num);
    } else if (error_type == BIND_ERROR )
    {
        LogError("[MapVotes] Bind Error (errno %d)", error_num);
    } else if (error_type == RECV_ERROR )
    {
        LogError("[MapVotes] Recieve Error (errno %d)", error_num);
    } else if (error_type == LISTEN_ERROR )
    {
        LogError("[MapVotes] Listen Error (errno %d)", error_num);
    } else
    {
        LogError("[MapVotes] socket error %d (errno %d)", error_type, error_num);
    }

    if(client)
    {
        PrintToChat(client, "[MapVotes] socket error %d (errno %d)", error_type, error_num);
    }

    CloseHandle(headers_pack);
    CloseHandle(socket);
}

BuildMapListAndTrie()
{
    //Build the map list
    if (ReadMapList(g_MapList,
                g_MapFileSerial,
                "nominations",
                MAPLIST_FLAG_CLEARARRAY|MAPLIST_FLAG_MAPSFOLDER)
            == INVALID_HANDLE)
    {
        if (g_MapFileSerial == -1)
        {
            SetFailState("Unable to create a valid map list.");
        }else{
            //Build the map trie; note we don't care about the value, just if the map exists in the trie
            ClearTrie(g_MapTrie);

            for (new i = 0; i < GetArraySize(g_MapList); i++)
            {
                GetArrayString(g_MapList, i, map, sizeof(map));
                SetTrieValue(g_mapTrie, map, 1);
            }
        }
    }
}


//By 11530
//GetSteamAccountID(client) does not work because we don't have 64 bit types
stock bool:GetCommunityIDString(const String:SteamID[], String:CommunityID[], const CommunityIDSize) 
{ 
    decl String:SteamIDParts[3][11]; 
    new const String:Identifier[] = "76561197960265728"; 

    if ((CommunityIDSize < 1) || (ExplodeString(SteamID, ":", SteamIDParts, sizeof(SteamIDParts), sizeof(SteamIDParts[])) != 3)) 
    { 
        CommunityID[0] = '\0'; 
        return false; 
    } 

    new Current, CarryOver = (SteamIDParts[1][0] == '1'); 
    for (new i = (CommunityIDSize - 2), j = (strlen(SteamIDParts[2]) - 1), k = (strlen(Identifier) - 1); i >= 0; i--, j--, k--) 
    { 
        Current = (j >= 0 ? (2 * (SteamIDParts[2][j] - '0')) : 0) + CarryOver + (k >= 0 ? ((Identifier[k] - '0') * 1) : 0); 
        CarryOver = Current / 10; 
        CommunityID[i] = (Current % 10) + '0'; 
    } 

    CommunityID[CommunityIDSize - 1] = '\0'; 
    return true; 
}  

public MapVotesCall(String:route[128], String:query_params[512], client, SocketReceiveCB:rfunc)
{
    new port= GetConVarInt(g_Cvar_MapVotesPort);
    decl String:base_url[128], String:api_key[128];
    GetConVarString(g_Cvar_MapVotesUrl, base_url, sizeof(base_url));
    GetConVarString(g_Cvar_MapVotesApiKey, api_key, sizeof(api_key));

    ReplaceString(base_url, sizeof(base_url), "http://", "", false);
    ReplaceString(base_url, sizeof(base_url), "https://", "", false);

    Format(query_params, sizeof(query_params), "%s&access_token=%s", query_params, api_key);

    HTTPPost(base_url, route, query_params, port, client, rfunc);
}

public HTTPPost(String:base_url[128], String:route[128], String:query_params[512], port, client, SocketReceiveCB:rfunc)
{
    new Handle:socket = SocketCreate(SOCKET_TCP, OnSocketError);

    //This Formats the headers needed to make a HTTP/1.1 POST request.
    new String:request_string[1024];
    Format(request_string, sizeof(request_string),
            "POST %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\nContent-type: application/x-www-form-urlencoded\r\nContent-length: %d\r\n\r\n%s",
            route,
            base_url,
            strlen(query_params),
            query_params);

    new Handle:headers_pack = CreateDataPack();
    WritePackCell(headers_pack, GetClientUserId(client));
    WritePackString(headers_pack, request_string);
    SocketSetArg(socket, headers_pack);

    SocketConnect(socket, OnSocketConnected, OnSocketReceive, OnSocketDisconnected, base_url, port);
}

//Parse an http post response to strip out the header and byte counts to get the json string
public Handle:ParseJson(String:receive_data[])
{
    new String:raw[2][1024], String:line[2][1024];
    ExplodeString(receive_data, "\r\n\r\n", raw, sizeof(raw), sizeof(raw[]));
    ExplodeString(raw[1], "\r\n", line, sizeof(line), sizeof(line[]));

    return json_load(line[1]);
}

public WriteMessage(client, String:message[256])
{
    //Encode the message to be url safe
    decl String:base64[256], String:base64_url[256];
    EncodeBase64(base64, sizeof(base64), message);
    Base64MimeToUrl(base64_url, sizeof(base64_url), base64);

    decl String:buffer[MAX_STEAMID_LENGTH], String:uid[MAX_COMMUNITYID_LENGTH];
    GetClientAuthString(client, buffer, sizeof(buffer));
    GetCommunityIDString(buffer, uid, sizeof(uid));

    decl String:query_params[512], String:map[PLATFORM_MAX_PATH];
    GetCurrentMap(map, sizeof(map));
    Format(query_params, sizeof(query_params),
            "map=%s&uid=%s&comment=%s&base64=true", map, uid, base64);

    MapVotesCall(WRITE_MESSAGE_ROUTE, query_params, client, ReceiveWriteMessage);
}

public ReceiveWriteMessage(Handle:socket, String:receive_data[], const data_size, any:headers_pack)
{
    ResetPack(headers_pack);
    decl client = GetClientOfUserId(ReadPackCell(headers_pack));

    if(client)
    {
        PrintToChat(client, "[MapVotes] Comment Added");
    }
}

public CastVote(client, value)
{
    decl String:buffer[MAX_STEAMID_LENGTH], String:uid[MAX_COMMUNITYID_LENGTH];
    GetClientAuthString(client, buffer, sizeof(buffer));
    GetCommunityIDString(buffer, uid, sizeof(uid));

    if(!(value == -1 || value == 0 || value == 1)){
        LogError("[MapVotes] invalid vote value %d (steam_user: %s)", value, uid);
    }else{
        decl String:query_params[512], String:map[PLATFORM_MAX_PATH];

        GetCurrentMap(map, sizeof(map));

        Format(query_params, sizeof(query_params),
                "map=%s&uid=%s&value=%d", map, uid, value);

        MapVotesCall(CAST_VOTE_ROUTE, query_params, client, ReceiveCastVote);
    }

}

public ReceiveCastVote(Handle:socket, String:receive_data[], const data_size, any:headers_pack)
{
    ResetPack(headers_pack);
    decl client = GetClientOfUserId(ReadPackCell(headers_pack));

    if(client)
    {
        PrintToChat(client, "[MapVotes] Vote Cast");
    }
}

public Favorite(String:map[PLATFORM_MAX_PATH], client, bool:favorite)
{
    decl String:buffer[MAX_STEAMID_LENGTH], String:uid[MAX_COMMUNITYID_LENGTH];
    GetClientAuthString(client, buffer, sizeof(buffer));
    GetCommunityIDString(buffer, uid, sizeof(uid));
    decl String:query_params[512];

    Format(query_params, sizeof(query_params),
            "map=%s&uid=%s", map, uid);

    if(favorite)
    {
        MapVotesCall(FAVORITE_ROUTE, query_params, client, ReceiveFavorite);
    }else{
        MapVotesCall(UNFAVORITE_ROUTE, query_params, client, ReceiveFavorite);
    }
}

public ReceiveFavorite(Handle:socket, String:receive_data[], const data_size, any:headers_pack)
{
    ResetPack(headers_pack);
    decl client = GetClientOfUserId(ReadPackCell(headers_pack));

    if(client)
    {
        PrintToChat(client, "[MapVotes] Updated Favorites");
    }
}


public MapSearch(client, String:search_key[PLATFORM_MAX_PATH], Handle:map_list, MenuHandler:handler)
{
    new String:map[PLATFORM_MAX_PATH], String:info[16];
    new Handle:menu = CreateMenu(handler, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem|MenuAction_DisplayItem);
    new bool:found = false;

    for(new i=0; i<GetArraySize(map_list); i++)
    {
        GetArrayString(mapList, i, map, sizeof(map));

        //If this map matches the search key, add it to the menu
        if(StrContains(map, search_key, false) >= 0){
            AddMenuItem(menu, map, map);
            found = true;
        }
    }

    if(found)
    {
        SetMenuTitle(menu, "Found Maps");
        DisplayMenu(menu, client, MENU_TIME_FOREVER);
    }

}

public FavoriteSearchHandler(Handle:menu, MenuAction:action, param1, param2)
{
    if (action == MenuAction_End)
    {
        CloseHandle(menu);
    } else if (action == MenuAction_VoteCancel)
    {
    } else if (action == MenuAction_Select)
    {
        new client=param1;
        new String:map[PLATFORM_MAX_PATH];
        GetMenuItem(menu, param2, info, sizeof(info));
        Favorite(map, client, true);
    }
}

public UnfavoriteSearchHandler(Handle:menu, MenuAction:action, param1, param2)
{
    if (action == MenuAction_End)
    {
        CloseHandle(menu);
    } else if (action == MenuAction_VoteCancel)
    {
    } else if (action == MenuAction_Select)
    {
        new client=param1;
        new String:map[PLATFORM_MAX_PATH];
        GetMenuItem(menu, param2, info, sizeof(info));
        Unfavorite(map, client, false);
    }
}

public GetFavorites(client)
{
    decl String:buffer[MAX_STEAMID_LENGTH], String:uid[MAX_COMMUNITYID_LENGTH];
    GetClientAuthString(client, buffer, sizeof(buffer));
    GetCommunityIDString(buffer, uid, sizeof(uid));
    decl String:query_params[512];

    //NOTE: uid is the client's steamid64 while player is the client's userid; the index incremented for each client that joined the server
    Format(query_params, sizeof(query_params),
            "player=%i&uid=%s", GetClientUserId(client), uid);

    MapVotesCall(GET_FAVORITES_ROUTE, query_params, client, ReceiveGetFavorites);
}

public ReceiveGetFavorites(Handle:socket, String:receive_data[], const data_size, any:headers_pack)
{
    ResetPack(headers_pack);
    decl client = GetClientOfUserId(ReadPackCell(headers_pack));

    new Handle:json = ParseJson(receive_data);
    new Handle:maps = json_object_get(json, "maps");
    new String:map_buffer[PLATFORM_MAX_PATH];

    new Handle:menu = CreateMenu(NominateMapHandler);

    for(new i = 0; i < json_array_size(maps); i++)
    {
        json_array_get_string(maps, i, map_buffer, sizeof(map_buffer));
        if(GetTrieValue(g_MapTrie, map, _))
        {
            AddMenuItem(menu, map, map);
        }
    }

    //If no maps were found don't even bother displaying a menu
    if(GetMenuItemCount(mapSearchedMenu) > 0){
        SetMenuTitle(menu, "Favorited Maps");
        DisplayMenu(menu, client, MENU_TIME_FOREVER);
    }else{
        PrintToChat(client, "[MapVotes] You have no favorited maps that are on this server.")
    }
}


public NominateMapHandler(Handle:menu, MenuAction:action, param1, param2)
{

    decl result;

    // Start function call
    Call_StartFunction(g_nominations, g_Handler_MapSelectMenu);

    // Push parameters one at a time
    Call_PushCell(menu);
    Call_PushCell(action);
    Call_PushCell(param1);
    Call_PushCell(param2);

    // Finish the call, get the result
    Call_Finish(result);

    return result;
}


public CallVoteOnClient(client)
{
    new Handle:menu = CreateMenu(VoteMenuHandler);
    SetMenuTitle(menu, "Do you like this map?");
    AddMenuItem(menu, "1","Like it.");
    AddMenuItem(menu, "-1","Hate it.");
    AddMenuItem(menu, "0","I have no strong feelings one way or the other.");
    DisplayMenu(menu, client, 20);
}

public VoteMenuHandler(Handle:menu, MenuAction:action, param1, param2)
{
    if (action == MenuAction_End)
    {
        CloseHandle(menu);
    } else if (action == MenuAction_VoteCancel)
    {
    } else if (action == MenuAction_Select)
    {
        new String:info[32];
        GetMenuItem(menu, param2, info, sizeof(info));
        new value = StringToInt(info);

        CastVote(param1, value);
    }
}

public HaveNotVoted()
{
    decl String:buffer[MAX_STEAMID_LENGTH], String:uid[MAX_COMMUNITYID_LENGTH];
    new String:query_buffer[512], String:query_params[512], String:map[PLATFORM_MAX_PATH];
    new player;

    GetCurrentMap(map, sizeof(map));
    Format(query_params, sizeof(query_params), "map=%s&", map);

    for (new i=1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }
        GetClientAuthString(client, buffer, sizeof(buffer));
        GetCommunityIDString(buffer, uid, sizeof(uid));
        player = GetClientUserId(client);

        Format(query_buffer, sizeof(query_buffer),
                "&uids=%s&players=%d", uid, value);

        StrCat(query_params, sizeof(query_params), query_buffer);
    }

    MapVotesCall(HAVE_NOT_VOTED_ROUTE, query_params, 0, OnSocketReceive);
}
public ParseHaveNotVoted(Handle:json)
{
    new Handle:players = json_object_get(json, "players");
    new p;
    new String:map_buffer[PLATFORM_MAX_PATH];

    for(new i = 0; i < json_array_size(players); i++)
    {
        p = json_array_get_int(players, i);
        CallVoteOnClient(GetClientOfUserId(p))
    }
}

public ViewMap(client)
{
    decl String:map[PLATFORM_MAX_PATH], String:url[256], String:base_url[128];
    GetCurrentMap(map, sizeof(map));
    GetConVarString(g_Cvar_MapVotesUrl, base_url, sizeof(base_url));
    ReplaceString(base_url, sizeof(base_url), "http://", "", false);
    ReplaceString(base_url, sizeof(base_url), "https://", "", false);

    Format(url, sizeof(url),
            "http://%s%s/%s", base_url, MAPS_ROUTE, map);

    ShowMOTDPanel(client, "Map Viewer", url, MOTDPANEL_TYPE_URL);

}


public Action:Test(client, args)
{
    decl String:query_params[512];

    //NOTE: uid is the client's steamid64 while player is the client's userid; the index incremented for each client that joined the server
    Format(query_params, sizeof(query_params),
            "player=%i&uid=%s", 7, "76561197998903004");

    MapVotesCall(GET_FAVORITES_ROUTE, query_params, 0, OnSocketReceive);
}

