# ROOMVA 2.9 Architecture Documentation

## System Overview
ROOMVA is an autonomous mapping turtle system for ComputerCraft that explores, maps, and navigates multi-room environments with automatic room detection and door identification.

---

## File Structure

```
/maps/
├── fullmap/
│   └── scans/
│       ├── worldmap.txt      # Complete map: x y z value(0=free,1=blocked)
│       ├── blockmap.txt      # Block types: x y z blockName
│       ├── rooms.txt         # Room definitions with bounding boxes
│       ├── doors.txt         # Detected 3x3 door patterns
│       └── links.txt         # Room connectivity graph
├── room_0/
│   └── scans/
│       ├── worldmap.txt      # Room-specific map data
│       └── blockmap.txt      # Room-specific block types
├── room_1/
│   └── scans/
│       └── ...
├── monitor_cache/            # Cache for monitor persistence
├── roomva_debug.txt          # Debug log (when DEBUG=true)
├── roomva_blockscanlog.txt   # Block scan history
└── roomva_scanned_rooms.txt  # Completed room scan tracking

/apis/
└── A                         # GPS/Navigation library (A.lua)

main.lua                      # ROOMVA main program (1802 lines)
```

---

## Logic Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        ROOMVA 2.9 STARTUP                        │
└────────────────┬────────────────────────────────────────────────┘
                 │
                 ├─► Load APIs (A.lua for GPS/Navigation)
                 ├─► Initialize Rednet (modemSide="right")
                 ├─► Load Configuration (cfg table)
                 └─► Start 7 Parallel Threads ──┐
                                                  │
┌─────────────────────────────────────────────────┴───────────────┐
│                    PARALLEL THREAD SYSTEM                        │
└──────────────────────────────────────────────────────────────────┘

Thread 1: MAIN PATROL LOOP
┌──────────────────────────────────────────────────────────────────┐
│ ┌──────────────┐                                                 │
│ │ GPS Lock     │──► Load Existing Maps (loadMapFromFiles)       │
│ └──────────────┘                                                 │
│         │                                                         │
│         ├─► If no maps: Initial Spiral Scan (8 block radius)    │
│         │                                                         │
│         ├─► Build Clusters (BFS room detection)                  │
│         │                                                         │
│         ├─► Detect Doors (3x3 patterns in XY/XZ/YZ planes)      │
│         │                                                         │
│         └─► Save Map Files (rebuildAndSaveMaps)                  │
│                                                                   │
│ ┌──────────────────────────────────────────────────────────┐    │
│ │                    PATROL LOOP                           │    │
│ │                                                           │    │
│ │  ┌──────────────────────────────────────────────┐       │    │
│ │  │ Determine Current Room                       │       │    │
│ │  │  • getCurrentRoomFromFile() [Fast Lookup]    │       │    │
│ │  │  • determineRoomByScan() [If not found]      │       │    │
│ │  └──────────────────────────────────────────────┘       │    │
│ │                      │                                    │    │
│ │                      ▼                                    │    │
│ │  ┌──────────────────────────────────────────────┐       │    │
│ │  │ Check Job Queue                              │       │    │
│ │  │  • Goto Room Command? → Navigate             │       │    │
│ │  │  • Explore Mode? → explore.step()            │       │    │
│ │  │  • Random Wander? (20% chance)               │       │    │
│ │  └──────────────────────────────────────────────┘       │    │
│ │                      │                                    │    │
│ │                      ▼                                    │    │
│ │  ┌──────────────────────────────────────────────┐       │    │
│ │  │ Search for Unmapped Areas (5 block radius)   │       │    │
│ │  │  • If found → Navigate and Scan              │       │    │
│ │  └──────────────────────────────────────────────┘       │    │
│ │                      │                                    │    │
│ │                      ▼                                    │    │
│ │  ┌──────────────────────────────────────────────┐       │    │
│ │  │ Normal Patrol                                 │       │    │
│ │  │  • Pick random point in current room         │       │    │
│ │  │  • Navigate (A.moveTo)                       │       │    │
│ │  │  • Check Fuel                                 │       │    │
│ │  └──────────────────────────────────────────────┘       │    │
│ │                      │                                    │    │
│ │                      └──► sleep(0.5s) ──► LOOP          │    │
│ └──────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘

Thread 2: HEARTBEAT (1.0s interval)
┌──────────────────────────────────────────────────────────────────┐
│ Every 1.0 seconds:                                               │
│   ├─► Get GPS Position (A.setLocationFromGPS)                   │
│   ├─► Determine Current Room (determineCurrentRoom)             │
│   ├─► Check/Refuel (if fuel < 1000)                            │
│   └─► Send Heartbeat Packet via Rednet                          │
│       Protocol: "HB"                                             │
│       Payload: {heartbeat, name, fuel, currentRoom, x, y, z}    │
└──────────────────────────────────────────────────────────────────┘

Thread 3: REDNET COMMAND LISTENER
┌──────────────────────────────────────────────────────────────────┐
│ Listens for incoming commands:                                   │
│                                                                   │
│ Protocol: "ROOMVA"                                               │
│   ├─► goto_room → Set pendingRoomTarget                         │
│   ├─► explore_on → Enable exploration mode                      │
│   └─► explore_off → Disable exploration mode                    │
│                                                                   │
│ Protocol: "ROOMVA_CMD"                                           │
│   └─► map_request → Trigger map refresh                         │
│                                                                   │
│ Protocol: "DEBUG"                                                │
│   └─► DEBUG_SW → Toggle block scan streaming                    │
│                                                                   │
│ Special: {logfrompocket="REFRESH_REQUEST"}                      │
│   └─► Restart program                                            │
└──────────────────────────────────────────────────────────────────┘

Thread 4: JOB QUEUE PROCESSOR
┌──────────────────────────────────────────────────────────────────┐
│ Same as Thread 3 (jobs.jobListenerLoop)                         │
│ Handles queued commands from monitor/pocket computers           │
└──────────────────────────────────────────────────────────────────┘

Thread 5: MAP AUTOSAVE (5.0s interval)
┌──────────────────────────────────────────────────────────────────┐
│ Every 5.0 seconds:                                               │
│   ├─► Build Clusters (BFS room detection)                       │
│   └─► Rebuild and Save Maps                                     │
│       ├─► /maps/fullmap/scans/worldmap.txt                      │
│       ├─► /maps/fullmap/scans/blockmap.txt                      │
│       ├─► /maps/fullmap/scans/rooms.txt                         │
│       ├─► /maps/fullmap/scans/doors.txt                         │
│       ├─► /maps/fullmap/scans/links.txt                         │
│       └─► /maps/room_N/scans/* (per-room files)                │
└──────────────────────────────────────────────────────────────────┘

Thread 6: MAP BROADCAST (5.0s interval)
┌──────────────────────────────────────────────────────────────────┐
│ Every 5.0 seconds:                                               │
│   ├─► Read worldmap.txt and rooms.txt                           │
│   ├─► Build packet: {mapfile, roomsfile}                        │
│   └─► Broadcast to Monitor (#3)                                 │
│       Protocol: "ROOMVA_MAPFILE"                                 │
│       Logs packet size to debug file                             │
└──────────────────────────────────────────────────────────────────┘

Thread 7: SMART EXPLORATION (0.5s interval)
┌──────────────────────────────────────────────────────────────────┐
│ When exploreMode=true:                                           │
│   ├─► Find Nearest Unmapped Block (up to 2400 block radius)     │
│   ├─► Navigate to target (A.moveTo)                             │
│   └─► Scan area (explore.step)                                  │
└──────────────────────────────────────────────────────────────────┘

---

## Core Algorithms

### 1. Room Detection (Clustering)
```
buildClusters():
  ┌─► Collect all free (val=0) blocks
  │
  ├─► BFS (Breadth-First Search):
  │     For each unvisited free block:
  │       ├─► Start flood fill
  │       ├─► Mark connected blocks (6-directional)
  │       ├─► Track bounding box [minX..maxX, minY..maxY, minZ..maxZ]
  │       └─► Calculate metadata (size, volume, avgNeighbors)
  │
  └─► Return clusters with metadata
      Types: tiny (≤10), smallRoom (≤50), room, largeRoom (≥200)
```

### 2. Door Detection (3x3 Pattern Matching)
```
detectDoors(clusters):
  ┌─► Map each free block to its room ID
  │
  ├─► Find all blocked (val=1) blocks
  │
  ├─► For each blocked block:
  │     Check if it's the center of a 3x3 pattern:
  │       ├─► XY plane (door facing Z): 3x3 grid at constant Z
  │       ├─► XZ plane (door facing Y): 3x3 grid at constant Y
  │       └─► YZ plane (door facing X): 3x3 grid at constant X
  │
  ├─► For each valid 3x3 pattern:
  │     ├─► Check 6 adjacent positions (±X, ±Y, ±Z)
  │     ├─► Find which rooms are adjacent
  │     └─► If ≥2 rooms found → Record door
  │
  └─► Return door list with {x, y, z, plane, room1, room2}
```

### 3. Current Room Determination
```
determineCurrentRoom(x, y, z):
  ┌─► Fast Lookup: getCurrentRoomFromFile()
  │     ├─► Read /maps/fullmap/scans/rooms.txt
  │     ├─► Parse bbox format: bboxX=[min..max] ...
  │     ├─► Check if position in bbox (with ±1 buffer)
  │     └─► Return room# if match
  │
  ├─► If not found → Scan Mode:
  │     ├─► scanAroundHere() [4 directions + up/down]
  │     ├─► buildClusters() [temporary clustering]
  │     ├─► getCurrentRoom() [find which cluster contains position]
  │     └─► handleRoomDetection():
  │           ├─► Validate position in room bounds
  │           ├─► Check for adjacent saved rooms (findAdjacentRoom)
  │           ├─► Check for 3x3 door patterns (checkDoorBetweenPositions)
  │           └─► Decide: Merge with existing room OR New room
  │
  └─► Return room# or nil
```

### 4. Door-Based Room Merging Logic
```
handleRoomDetection(x, y, z, tempRoom, tempClusters):
  ┌─► Validate position is within detected room bounds
  │
  ├─► Search for adjacent saved rooms (up to 50 rooms)
  │     └─► isAdjacentToRoom() [Euclidean distance ≤2 blocks]
  │
  ├─► If adjacent room found:
  │     ├─► Check for 3x3 door between positions
  │     │     └─► checkDoorBetweenPositions() [6-block search radius]
  │     │           • Check XY plane doors
  │     │           • Check XZ plane doors  
  │     │           • Check YZ plane doors
  │     │
  │     ├─► If door found → Keep as separate room
  │     └─► If no door → Merge with adjacent room
  │
  └─► If no adjacent room → New room discovered
```

---

## Data Structures

### Map World Storage
```lua
map.world = {
  ["x:y:z"] = {
    val = 0 or 1,           -- 0=free, 1=blocked
    name = "minecraft:air"  -- Block type identifier
  }
}
```

### Cluster Metadata
```lua
cluster = {
  cells = { {x, y, z, key}, ... },
  meta = {
    size = 150,             -- Number of blocks
    volume = 1000,          -- Bounding box volume
    avgNeighbors = 4.5,     -- Avg connected neighbors
    minX, maxX,             -- Bounding box
    minY, maxY,
    minZ, maxZ,
    type = "room"           -- tiny/smallRoom/room/largeRoom
  }
}
```

### Door Record
```lua
door = {
  x = 100, y = 64, z = 200,   -- Door center position
  plane = "XY",                -- XY/XZ/YZ orientation
  room1 = 0,                   -- First connected room
  room2 = 1                    -- Second connected room
}
```

---

## Network Protocols

### Outgoing Protocols (Turtle → Monitor/Pocket)

| Protocol | Interval | Payload | Purpose |
|----------|----------|---------|---------|
| `HB` | 1.0s | `{heartbeat, name, fuel, currentRoom, x, y, z}` | Position tracking |
| `ROOMVA_MAPFILE` | 5.0s | `{mapfile, roomsfile}` | Map synchronization |
| `ROOMVA_BLOCKSCAN` | On-demand | `{blockscan: "time x y z blockName"}` | Debug streaming |
| `ROOMVA_STATUS` | On scan | `{status, time, clusters}` | Scan completion |
| `stats` | On log | `{log: "[ROOMVA] message"}` | Log forwarding |

### Incoming Protocols (Monitor/Pocket → Turtle)

| Protocol | Command | Action |
|----------|---------|--------|
| `ROOMVA` | `{roomva_cmd="goto_room", room_index=N}` | Navigate to room N |
| `ROOMVA` | `{roomva_cmd="explore_on"}` | Enable exploration |
| `ROOMVA` | `{roomva_cmd="explore_off"}` | Disable exploration |
| `ROOMVA_CMD` | `{map_request=true}` | Send full map |
| `DEBUG` | `{debug_cmd="DEBUG_SW"}` | Toggle debug streaming |
| (any) | `{logfrompocket="REFRESH_REQUEST"}` | Restart program |

---

## Configuration Parameters

```lua
cfg = {
  -- Networking
  modemSide = "right",
  monitorID = 3,
  BROADCAST_MAP = true,
  
  -- Timing
  HEARTBEAT_INTERVAL = 1.0,      -- Heartbeat frequency
  AUTOSAVE_INTERVAL = 5.0,       -- Map save frequency
  BROADCAST_INTERVAL = 5.0,      -- Map broadcast frequency
  MOVE_DELAY = 0.5,              -- Patrol step delay
  EXPLORE_STEP_DELAY = 0.2,      -- Explore step delay
  SMART_EXPLORE_INTERVAL = 0.5,  -- Smart explore check
  
  -- Behavior
  MOVEMENT_THRESHOLD = 10,       -- Steps before extra heartbeat
  MULTI_ROOM_WANDER_CHANCE = 0.20,  -- 20% chance to switch rooms
  
  -- Fuel
  FUEL_WARN_LEVEL = 200,
  FUEL_WARN_INTERVAL = 60,
  
  -- Memory
  VISIT_MEMORY_SIZE = 50,        -- Remember last 50 locations
  VISIT_AVOID_RADIUS = 3,        -- Avoid within 3 blocks
  
  -- Exploration
  SMART_EXPLORE_RADIUS = 2400,   -- Max search radius for unmapped
  
  -- Debug
  DEBUG = true                    -- Enable debug logging
}
```

---

## Key Functions Reference

### Navigation
- `A.moveTo(x, y, z, facing)` - Navigate to coordinates (from A.lua API)
- `A.getLocation()` - Get current position and facing
- `A.setLocationFromGPS()` - Update position from GPS satellites
- `moveAndTrack(x, y, z)` - Move with visit tracking and heartbeat

### Scanning
- `scanOneFacing()` - Scan block in front, up, and down
- `scanAroundHere()` - 360° scan (4 rotations)
- `explore.step()` - Full scan + save cycle
- `map.updateBlock(x, y, z, blockName)` - Record block data

### Room Detection
- `getCurrentRoomFromFile(x, y, z)` - Fast file lookup
- `determineCurrentRoom(x, y, z)` - Full detection with fallback
- `determineRoomByScan(x, y, z)` - Scan-based detection
- `handleRoomDetection()` - Merge/separate logic

### Clustering & Doors
- `buildClusters()` - BFS room detection
- `detectDoors(clusters)` - 3x3 pattern matching
- `isAdjacentToRoom(x, y, z, roomNum)` - Proximity check
- `checkDoorBetweenPositions(x, y, z, roomNum)` - Door search

### File I/O
- `map.loadMapFromFiles()` - Load existing maps on startup
- `map.rebuildAndSaveMaps()` - Save full + per-room maps
- `sendFullMapFile(targetId)` - Broadcast map data

---

## Execution Model

```
STARTUP
   ↓
Initialize (GPS lock, load maps, build clusters)
   ↓
Launch 7 Parallel Threads ──────────────┐
   ↓                                     │
Thread 1 (Main Patrol) ←────┐           │
Thread 2 (Heartbeat)         │           │
Thread 3 (Command Listener)  ├─ parallel.waitForAny()
Thread 4 (Job Queue)         │           │
Thread 5 (Autosave)          │           │
Thread 6 (Broadcast)         │           │
Thread 7 (Smart Explore) ────┘           │
   ↓                                     │
First thread to exit ←───────────────────┘
   ↓
SHUTDOWN (or restart if restartFlag=true)
```

---

## Performance Characteristics

- **Map Storage**: O(n) where n = number of scanned blocks
- **Room Lookup**: O(1) from file, O(r) for scan (r = room count)
- **Clustering**: O(n) BFS traversal
- **Door Detection**: O(b²) where b = blocked blocks
- **Broadcast Size**: ~5-50 KB depending on map size
- **Memory**: Scales with explored area (not pre-allocated)

---

## Dependencies

- **A.lua**: GPS positioning and pathfinding API
- **ComputerCraft**: turtle, fs, rednet, parallel, os APIs
- **GPS System**: Requires 4+ GPS hosts for positioning
- **Monitor/Pocket**: Computer #3 for receiving broadcasts

---

## Debug Information

When `DEBUG=true`:
- All operations logged to `/maps/roomva_debug.txt`
- Block scans logged to `/maps/roomva_blockscanlog.txt`
- Packet sizes logged on every transmission
- Room detection logic fully traced
- Door detection results logged

View debug output:
```lua
-- On turtle
edit /maps/roomva_debug.txt

-- Or stream live with DEBUG protocol
-- Send {debug_cmd="DEBUG_SW"} to toggle streaming
```

---

## Version: ROOMVA 2.9
**Total Lines**: 1802  
**Modules**: All-in-one (previously separate modules now integrated)  
**Last Updated**: Current session
