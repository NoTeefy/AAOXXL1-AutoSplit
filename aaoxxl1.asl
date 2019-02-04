/*
	Astérix & Obélix Auto-Splitter XXL 1 (with loadless timer)
	Version: 0.0.8
	Author: NoTeefy
	Compatible Versions: Standalone (PC)
	Some code may be inspired by some referenced scripts and their authors: Avasam, DevilSquirrel, tduva, Darkid
	
	Thanks to Martyste for some ideas/inputs and Spiraster for his own approaches regarding the execution order of ASL scripts <3
	
	
	A little side note from the author:
	This script was made with the general idea of being dynamic/maintainable in an easy way while trying to be as performant as possible (hardcoded would be faster of course but it wouldn't be maintenance-friendly).
	How does it work? New structs/sig patterns can be added in the anonymous vars.triggerInit method.
	After that you just need to add a case for your struct in the update{} section and do whatever you want with that value.
	The only downside is the lack of direct access to other MemoryWatcher if that's needed for a comparison (e.g: finalBossHit is getting triggered but it needs to get checked against the current levelNumber).
	You can workaround this problem by hardcoding the right index into your section, use flags for different stuff or perform a second index search to get to the desired value.
	That's it - have fun and never forget: If you're throwing an exception LiveSplit automatically destroys all current cycles (update{}, start{}, reset{}, ...). You can't trust vars.triggerInit to perform a specific thing at another place after calling it.
*/
state("Gamemodule.elb") {
	
}

// Loading & func/var declaration
startup {
	vars.ver = "0.0.8";
	vars.cooldownStopwatch = new Stopwatch();
	refreshRate = 1000/500;
	
	// Log Output switch for DebugView (enables/disables debug messages)
    var DebugEnabled = false;
    Action<string> DebugOutput = (text) => {
        if (DebugEnabled) {
			print(" «[AAOXXL1 - v" + vars.ver + "]» " + text);
        }
    };
    vars.DebugOutput = DebugOutput;

	vars.DebugOutput("startup{} - Initialising auto-splitter"); 
	settings.Add("isLoadless", true, "Use loadless timer");
	settings.Add("alwaysStart", false, "Always start after a load has been triggered while not being on the overworld");
	
	Func<int, bool, bool, Tuple<int, bool, bool>> tc = Tuple.Create;
	vars.tc = tc;
	
	Func<String, SigScanTarget, int[], int, String, bool, Tuple<String, SigScanTarget, int[], int, String, bool>> tcStruct = Tuple.Create;
	vars.tcStruct = tcStruct;
	
	/*
		We need a deep copy function to reset the levelProgression when a runner exits & stops his timer while keeping the game open for a new run
		while not touching the values/references from the template itself (gotta love native C based languages...)
	*/
	Func<List<Tuple<int, bool, bool>>, List<Tuple<int, bool, bool>>> deepCopy = (listToCopy) => {
        var newList = new List<Tuple<int, bool, bool>>{};
		foreach(var obj in listToCopy) {
			newList.Add(vars.tc(obj.Item1, obj.Item2, obj.Item3));
		}
		return newList;
    };
	vars.deepCopy = deepCopy;
	
	/*
		This is the level order which the splitter expects you to route (ignored in this case, it will always split if entering the world for the first time)
		Values: int = levelNum, bool = mustSplit, bool = hasVisited(level)
		! We can't use named tuple indices because we are under C# 7.0 => tuple.Item1, tuple.ItemX, tuple2.Item1, ... to read the values
	*/
	var levelTuples = new List<Tuple<int, bool, bool>>{ // we can't use named tuple indices because we are under C# 7.0, int = levelNum, bool = mustSplit, bool = hasVisited(level)
		tc(0, false, true), // unknown state/main-menu
		tc(1, false, false), // gaul
		tc(2, true, false), // normandy
		tc(3, true, false), // greece
		tc(4, true, false), // helvetia
		tc(5, true, false), // egypt
		tc(6, true, false), // rome
		tc(7, false, true), // overworld
		tc(8, false, true) // credits
	};
	
	vars.levelProgressionTemplate = levelTuples;
	
	/*
		Resets all important/dynamic values back to their initial value (used if timer gets stopped before all splits were done)
	*/
	Action resetValues = () => {
		vars.initialized = false;
		vars.watcherValues = new Dictionary<string, Tuple<String, String>> {};
		vars.watcherList = new List<Tuple<String, SigScanTarget, int[], int, String, bool>>{};
		vars.shouldStart = false;
		vars.shouldSplit = false;
		vars.shouldPause = false;
		vars.shouldReset = false;
		vars.isOnFirstLevel = false;
		vars.isOnFinalLevel = false;
		vars.gameDone = false;
		vars.runStarted = false;
		vars.skipFirstSplit = false;
		vars.levelProgression = vars.deepCopy(vars.levelProgressionTemplate);
	};
	vars.resetValues = resetValues;
	vars.resetValues();
	
	/*
	vars.isInCutsceneST = new SigScanTarget(0,
		"50 ?? ?? 02 24 ?? ?? 02 3C 00 00 00 40" // needs offsets of 0x74, 0x4DC for the right address (triple pointer)
	);
	*/
	
	vars.isIntroDoneST = new SigScanTarget(0,
		"14 ?? ?? 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 44" // (needs an offset of 0x24)
	);
	
	vars.levelNumberST = new SigScanTarget(0,
		"EC 59 64 00 C2 04 00 8B 49 0C 8B 04 81 85 C0" // (needs an offset of 0x20)
	);
	
	vars.finalLeverST = new SigScanTarget(0,
		"30 ?? ?? ?? ?? ?? ?? 02 00 00 00 00 ?? ?? ?? ?? ??" // (offsets: 0x80, 0xC)
	);
	
	vars.isLoadingST = new SigScanTarget(0,
		"B4 2C 66 00 C7 46 34 A0 2B 66 00 C7 46 ?? ?? ?? ?? ?? C7 46 ?? ?? ?? ?? ?? C7 46 ?? ?? ?? ?? ?? C7 46 ?? ?? ?? ?? ?? 8B ?? ?? ?? ?? ?? 83 E1 FE" // (offsets: 0xE0)
	);
	
	/*
		Resolves a multilevelpointer and returns its address (or IntPtr.Zero if nothing was found).
		It takes the following parameters: Process, module, signature name, signature structure, offsets of the multilevel pointers as an int-array, baseOffset of the first pointer if the signature was negatively/positively offsetted
		
		IMPORTANT!
		Has a cooldown of 125ms per read to prevent high CPU usage or crashes if no pointers are getting found in a loop without locking the thread
	*/
	Func<Process, ProcessModuleWow64Safe, String, SigScanTarget, int[], int, IntPtr> readMultipointer = (proc, module, sigName, sigTarget, offsets, baseOffset) => {
		var ptrToResolve = IntPtr.Zero;
		if(!vars.cooldownStopwatch.IsRunning) { // prevent errors if the start wasn't triggered in caller method
			vars.cooldownStopwatch.Start();
			return IntPtr.Zero;
		}
		var elapsed = vars.cooldownStopwatch.Elapsed.TotalMilliseconds;
		if(elapsed >= 0.0125) {
			vars.cooldownStopwatch.Restart();
			vars.DebugOutput("readMultipointer{} - sig scan starting for [" + sigName + "]");
			foreach (var page in proc.MemoryPages(true)) {
					var scanner = new SignatureScanner(proc, page.BaseAddress, (int)page.RegionSize);

					if (ptrToResolve == IntPtr.Zero) {
						ptrToResolve = scanner.Scan(sigTarget);
					} else {
						IntPtr basePointer = new IntPtr(ptrToResolve.ToInt64() + baseOffset);
						vars.DebugOutput("readMultipointer{} - found base pointer for [" + sigName + "] at " + basePointer.ToString("X"));
						var baseModuleOffset = (int)basePointer - (int)module.BaseAddress;
						DeepPointer dP = new DeepPointer(baseModuleOffset, offsets);
						IntPtr resolvedPtr = new IntPtr();
						dP.DerefOffsets(proc, out resolvedPtr);
						if(resolvedPtr != IntPtr.Zero) {
							vars.DebugOutput("readMultipointer{} - sig scan found [" + sigName + "] at " + resolvedPtr.ToString("X"));
							return resolvedPtr;
						}
						else {
							vars.DebugOutput("readMultipointer{} - sig scan failed for [" + sigName + "] or returned a null-pointer");
							return IntPtr.Zero;
						}
					}
			}
			vars.DebugOutput("readMultipointer{} - sig scan did not find a result in the memory pages");
			return IntPtr.Zero;
		}
		return IntPtr.Zero;
	};
	vars.readMultipointer = readMultipointer;
	
	
	/*
		Handles all of the initialization. Can be called multiple times (if a runner resets his run as an example) to make sure that the pointers aren't broken.
		Needs the following parameters: refreshRate, game, modules.First()
	*/
	Action<double, Process, ProcessModuleWow64Safe> triggerInit = (refresh, proc, module) => {
		vars.DebugOutput("triggerInit{} - called");
		refreshRate = 1000/500; // limit the cycles to 500ms
		vars.resetValues();
		vars.watchers = new MemoryWatcherList() {};
		vars.cooldownStopwatch.Start(); // starting stopwatch to make sure that the more intensive computations (sig scans etc) aren't processed too frequently
		
		vars.watcherList = new List<Tuple<String, SigScanTarget, int[], int, String, bool>>{
			//vars.tcStruct("isInCutscene", vars.isInCutsceneST, new int[]{ 0x74, 0x4DC }, 0x0, "bool", false),
			vars.tcStruct("isLoading", vars.isLoadingST, new int[]{ 0xE0 }, 0x0, "bool", false),
			vars.tcStruct("levelNumber", vars.levelNumberST, new int[]{ 0x20 }, 0x0, "byte", false),
			vars.tcStruct("finalLever", vars.finalLeverST, new int[]{ 0x80, 0xC }, 0x0, "bool", false),
			vars.tcStruct("isIntroDone", vars.isIntroDoneST, new int[]{ 0x24 }, 0x0, "bool", false)
		};
		
		List<Tuple<String, SigScanTarget, int[], int, String, bool>> watcherList = vars.watcherList;
		
		for(var i = 0; i < watcherList.Count; ++i) {
			bool initialized = false;
			var watcherToParse = watcherList[i];
			while(!initialized) {
				var ptr = vars.readMultipointer(proc, module, watcherToParse.Item1, watcherToParse.Item2, watcherToParse.Item3, watcherToParse.Item4);
				if(ptr != IntPtr.Zero) {
					initialized = true;
					var index = watcherList.FindIndex(t => t.Item1 == watcherToParse.Item1); // getting the right index
					watcherList[index] = vars.tcStruct(watcherToParse.Item1, watcherToParse.Item2, watcherToParse.Item3, watcherToParse.Item4, watcherToParse.Item5, true);
					switch(watcherToParse.Item5) {
						case "bool":
							vars.watchers.Add(new MemoryWatcher<bool>(ptr));
							break;
						case "byte":
							vars.watchers.Add(new MemoryWatcher<byte>(ptr));
							break;
						case "int":
							vars.watchers.Add(new MemoryWatcher<int>(ptr));
							break;
						default:
							vars.watchers.Add(new MemoryWatcher<int>(ptr));
							break;
					}
					break;
				}
				throw new Exception("triggerInit{} - Pointer: " + watcherToParse.Item1 + " failed or returned a null. " + "Initialization is not done yet!");
			}
		}
		
		refreshRate = 1000/14; // limit the cycles to 14ms
		vars.initialized = true;
		vars.cooldownStopwatch.Reset(); // resetting stopwatch since we don't need it to run anymore
	};
	vars.triggerInit = triggerInit;
}

// process found + hooked by LiveSplit (init needed vars)
init {
	vars.DebugOutput("init{} - Attached autosplitter to game client");
	vars.DebugOutput("init{} - Starting to search for the ingame memory region");
	refreshRate = 1000/500;
	vars.triggerInit(refreshRate, game, modules.First());
}

// gets triggered as often as refreshRate is set at | 70 = 1000ms / 70 => every 14ms
update {
	if(vars.initialized) {
		vars.watchers.UpdateAll(game);
		for(int i = 0; i < vars.watchers.Count; ++i) {
			// get the corresponding properties (which belong to this struct)
			Tuple<String, SigScanTarget, int[], int, String, bool> currentWatcher = vars.watcherList[i];
			MemoryWatcher currentWatcherValues = vars.watchers[i];
			if(!currentWatcherValues.Current.Equals(currentWatcherValues.Old)) {
				vars.DebugOutput("update{} - " + currentWatcher.Item1 + " changed from " + currentWatcherValues.Old + " to " + currentWatcherValues.Current);
				
				/*
					GENERAL SPLITTER LOGIC
					This dynamic function passes all changed values to their corresponding cases defined with the structs in var.striggerInit
					
				*/
				if(currentWatcherValues.Current != null) { // ignore nulled values
					switch(currentWatcher.Item1) { // switch the name of the structure that has triggered a changed value
						case "isLoading":
							vars.shouldPause = Convert.ToBoolean(currentWatcherValues.Current); // cast won't work because MemoryWatcher doesn't inherit a boolean type
							break;
						case "levelNumber":
							// check the current levelNumber against our level list to see if we need to split or reinitialise our values (reset)
							List<Tuple<int, bool, bool>> list = vars.levelProgression;
							int levelNum = Convert.ToInt32(currentWatcherValues.Current); // cast won't work because MemoryWatcher doesn't inherit an int type
							if((vars.gameDone || vars.runStarted) && levelNum == 0) { // game has been beaten or reset, runner goes back to main menu and is on loading phase
								refreshRate = 70;
								vars.DebugOutput("update{} - " + "run reset detected (game beaten or went back to main menu); reinitialising splitter");
								vars.shouldReset = true;
								vars.triggerInit(refreshRate, game, modules.First()); // resetting stuff
								return false;
							}
							if(levelNum == 6) {
								vars.isOnFinalLevel = true;
							}
							else if(levelNum == 1) {
								vars.isOnFirstLevel = true;
							}
							else {
								vars.isOnFinalLevel = false;
								vars.isOnFirstLevel = false;
							}
							if(settings["alwaysStart"] && !vars.runStarted && levelNum != 7 && levelNum != 0) {
								vars.shouldStart = true;
								vars.runStarted = true;
								vars.DebugOutput("update{} - " + "segmented start detected, gl & hf, may the frames be with you!");
								vars.skipFirstSplit = true;
							}
							var index = list.FindIndex(t => t.Item1 == levelNum); // getting the corresponding index for the level informations
							if(vars.levelProgression[index].Item2 && !vars.levelProgression[index].Item3) { // if level should be splitted and hasn't been visited yet
								vars.levelProgression[index] = vars.tc(levelNum, vars.levelProgression[index].Item2, true);
								if(vars.skipFirstSplit) {
									// skip first split for a segmented start
									vars.skipFirstSplit = false;
									vars.shouldSplit = false;
								}
								else {
									vars.shouldSplit = true;
								}
							}
							break;
						case "finalLever":
							// split if on last stage and finalLever changes to true
							if(vars.isOnFinalLevel && Convert.ToBoolean(currentWatcherValues.Current)) {
								vars.shouldSplit = true;
								vars.gameDone = true;
								vars.DebugOutput("update{} - " + "game has been beaten! Congrats!");
							}
							break;
						case "isIntroDone":
							if(vars.isOnFirstLevel && Convert.ToBoolean(currentWatcherValues.Current) && !vars.runStarted) {
								vars.shouldStart = true;
								vars.runStarted = true;
								vars.DebugOutput("update{} - " + "run has started, gl & hf, may the frames be with you!");
							}
							break;
						default: // do nothing if not specified
							break;
					}
				}
			}
		}
	}
	else {
		if(game.Handle != null) {
			if((int)game.Handle > 0) {
				vars.triggerInit(refreshRate, game, modules.First());
			}
		}
	}
}

// Only runs when the timer is stopped
start {
	if(vars.shouldStart) {
		vars.shouldStart = false;
		return true;
	}
	else if(vars.runStarted) {
		// manual reset detected
		refreshRate = 70;
		vars.DebugOutput("start{} - " + "manual reset (timer stopped) detected; reinitialising splitter");
		vars.triggerInit(refreshRate, game, modules.First()); // resetting stuff
	}
	return vars.shouldStart;
}

// Only runs when the timer is running
reset { // Resets the timer upon returning true
	if(vars.shouldReset) {
		vars.shouldReset = false;
		return true;
	}
	return vars.shouldReset;
}

// Splits upon returning true if reset isn't explicitly returning true
split {
	if(vars.shouldSplit) {
		vars.shouldSplit = false;
		return true;
	}
	return vars.shouldSplit;
}

// return true if timer needs to be stopped, return false if it should resume
isLoading {
	return settings["isLoadless"] && vars.shouldPause;
}
