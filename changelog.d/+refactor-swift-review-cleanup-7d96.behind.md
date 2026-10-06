GuessrKit's in-memory login and player stores are guarded by a compiler-checked Mutex, and its API calls build their JSON POSTs in one place.
