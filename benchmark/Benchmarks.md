# Benchmarks
## Methodology
Each tool fires an event 1000 times a frame for 10 seconds. Each bench is a pool of payloads, fired in turn:
`Booleans` and `Entities` send the same payload every time, and `BooleansRandom` and `EntitiesRandom` send a thousand
different ones a frame. Roblox compresses a remote's buffers with zstd, so identical events compress to almost nothing
and their bandwidth measures the compressor; the random benches leave it nothing to find.

`Fire ms` is the CPU time a frame's thousand fires took on the client. Studio caps the framerate at 60, so a tool at
60 FPS is bounded by the cap, not by its own cost, and this column still tells such tools apart. Studio compiles
LocalScripts natively, which most clients do not, so every tool looks faster here than on a player's device.

`Bytes/event` is what an event cost on the wire after Roblox's compression: every byte the client sent from the first
fire until its backlog drained, less what it sends idle, over the events fired. `Drain` is how long that backlog took
after the last fire. This replaced a `Kbps` column that sampled `Stats.DataSendKbps` -- kilobytes a second, not
kilobits -- once a second and scaled it by 60 / FPS. That read low for every tool below 60 FPS, since what a slow tool
fired went out after its sample and after the run: on the M1, Packet's EntitiesRandom came to 486 bytes an event, less
than the 600 bytes of random data in it. Tables older than this change still carry the `Kbps` column, and it should be
read with that in mind: no tool encodes Entities in fewer bytes than another (see below).

BlinkBlox's inbound limits are raised in the definition file for this, since a live server's defaults refuse most of
what the benchmark sends -- that is what they are for.

Blink is the original project BlinkBlox forked from, at its last release. `--download` fetches its source
into `tools/upstream`, and its own compiler builds `definitions/Definition.upstream.blink`, the same events without the
inbound limits, which Blink does not have, and without `Tiny`.

## Without Studio

`lune run Runtime` in this directory times every tool above on Lune, where Studio cannot: interpreted, as most
players' clients run code, and decoding on the server, which Studio does not time. It loads zap's and Blink's
generated modules, ByteNet and Packet from the same files Studio runs (after `lune run build --download`) with just
enough of Roblox mocked around them, and times a frame's thousand fires, the flush into packets, and the server decoding those packets
and calling its listener. `Bytes/event` is the encoder's output; `zstd` is that output compressed as Roblox would.

The run below was made on 2026-09-26 on an Apple M1 with 16 GB of memory, Lune 0.10.5, with this repository's
compiler (0.38.1). Each figure is the median of three runs, and each run's figure is itself a median or 99th percentile over
200 frames, in milliseconds per frame of 1000 events. `native` is what a Roblox server runs; `interpreted` is what most clients run.
Packet declares `--!native` nowhere, so both its rows are interpreted. `Tiny` is BlinkBlox's alone.

The code these modules run for a packet has not changed since 0.36.2: loaded side by side into one process, 0.36.2's and
0.38.1's modules decode at the same speed. The previous table, a single run of 0.36.2, read lower on some rows (EntitiesRandom
decode 10.81); that is this machine's spread between single runs, which is why this one takes three.

#### Booleans

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|3.840|4.289|0.011|4.539|5.080|128.00|0.02|
|Blink|native|6.673|7.288|0.051|12.116|12.767|1003.00|0.10|
|zap|native|34.990|72.794|0.056|13.375|25.022|1003.00|0.10|
|ByteNet|native|53.060|115.938|0.055|122.218|220.249|1003.00|0.10|
|Packet|native|124.344|245.250|0.080|116.657|224.886|1003.00|0.10|
|BlinkBlox|interpreted|38.244|78.837|0.013|45.105|80.002|128.00|0.02|
|Blink|interpreted|68.758|121.615|0.056|82.838|147.142|1003.00|0.10|
|zap|interpreted|173.871|333.277|0.064|105.967|188.211|1003.00|0.10|
|ByteNet|interpreted|126.532|219.912|0.058|121.730|235.561|1003.00|0.10|
|Packet|interpreted|125.137|252.592|0.081|116.287|323.154|1003.00|0.10|

#### Entities

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|3.200|10.213|0.026|13.334|34.081|603.00|0.67|
|Blink|native|3.175|5.877|0.033|73.307|147.730|603.00|0.67|
|zap|native|21.042|40.367|0.036|73.879|133.658|603.00|0.67|
|ByteNet|native|66.149|135.870|0.045|112.403|200.982|603.00|0.67|
|Packet|native|100.662|185.885|0.064|164.005|296.540|603.00|0.67|
|BlinkBlox|interpreted|33.463|61.670|0.031|54.971|97.933|603.00|0.67|
|Blink|interpreted|33.460|62.036|0.041|105.689|199.101|603.00|0.67|
|zap|interpreted|84.141|167.023|0.042|116.991|241.090|603.00|0.67|
|ByteNet|interpreted|109.171|207.828|0.044|110.594|198.959|603.00|0.67|
|Packet|interpreted|100.624|191.662|0.057|164.209|303.354|603.00|0.67|

#### BooleansRandom

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|8.615|10.452|0.012|4.832|6.412|128.00|125.82|
|Blink|native|17.609|32.376|0.058|12.284|27.555|1003.00|135.63|
|zap|native|45.475|75.268|0.057|13.380|25.480|1003.00|135.63|
|ByteNet|native|56.489|121.296|0.056|128.925|230.152|1003.00|135.63|
|Packet|native|132.202|245.129|0.082|125.370|281.905|1003.00|135.63|
|BlinkBlox|interpreted|40.436|84.849|0.015|46.280|89.162|128.00|125.82|
|Blink|interpreted|73.626|107.104|0.061|90.009|119.339|1003.00|135.63|
|zap|interpreted|171.321|324.150|0.064|105.940|199.698|1003.00|135.63|
|ByteNet|interpreted|134.375|223.618|0.062|128.666|222.122|1003.00|135.63|
|Packet|interpreted|132.443|211.694|0.080|124.625|233.307|1003.00|135.63|

#### EntitiesRandom

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|3.721|4.524|0.028|12.827|33.613|603.00|603.02|
|Blink|native|3.716|4.772|0.035|73.678|99.006|603.00|603.02|
|zap|native|21.981|44.740|0.037|73.918|150.363|603.00|603.02|
|ByteNet|native|66.675|138.657|0.054|111.605|225.458|603.00|603.02|
|Packet|native|101.054|179.028|0.065|164.893|298.385|603.00|603.02|
|BlinkBlox|interpreted|33.666|64.730|0.034|55.687|107.297|603.00|603.02|
|Blink|interpreted|33.609|55.034|0.039|107.329|160.484|603.00|603.02|
|zap|interpreted|84.138|178.186|0.041|119.161|239.545|603.00|603.02|
|ByteNet|interpreted|109.596|217.641|0.073|110.356|221.320|603.00|603.02|
|Packet|interpreted|100.934|197.721|0.059|162.204|301.232|603.00|603.02|

#### Tiny

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|0.135|0.157|0.001|0.385|0.437|2.00|0.02|
|BlinkBlox|interpreted|0.346|0.370|0.001|0.636|0.682|2.00|0.02|

Source code can be found [here](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src).  
Data used for benchmarks can be found [here](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches).   
Definition files used for benchmarks can be found [here](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/definitions).  
 
## Results

`P[NUMBER]` = [NUMBER] Percentile  
*The tables below were automatically generated by this [script](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/generate.luau).*
## Last Updated 2026-09-25 04:25:35 UTC
## Tool Versions
BlinkBlox: v0.36.2, compiled from this repository  
Blink: v0.18.9  
zap: v0.6.29  
ByteNet: v0.4.3  
Packet: 1.7.0  
## Computer Specs
Processor: `Apple M1`  
Memory: `16GB`  
## [Booleans](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/Booleans.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|16.00|17.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|Blink|53.00|60.00|49.00|48.00|48.00|46.00|0%|
|zap|35.00|38.00|31.00|31.00|31.00|26.00|0%|
|ByteNet|17.00|18.00|17.00|16.00|16.00|15.00|0%|
|Packet|15.00|16.00|15.00|15.00|15.00|15.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|29.22|25.91|32.53|39.12|42.18|62.07|0%|
|BlinkBlox|4.22|4.21|4.25|4.77|5.49|11.78|0%|
|Blink|8.42|6.77|10.34|11.54|13.09|17.80|0%|
|zap|25.89|24.95|29.23|33.90|39.18|51.25|0%|
|ByteNet|41.28|40.94|46.58|46.84|50.75|75.61|0%|
|Packet|67.34|67.11|76.18|81.43|89.54|117.47|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|3815.29|5.7|0%|
|BlinkBlox|0.04|2.4|0%|
|Blink|0.13|3.3|0%|
|zap|0.13|3.0|0%|
|ByteNet|0.12|3.3|0%|
|Packet|0.12|3.4|0%|
## [Entities](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/Entities.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|16.00|16.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|56.00|60.00|55.00|50.00|50.00|48.00|0%|
|Blink|22.00|23.00|21.00|21.00|21.00|19.00|0%|
|zap|22.00|23.00|22.00|20.00|20.00|20.00|0%|
|ByteNet|18.00|19.00|16.00|16.00|16.00|15.00|0%|
|Packet|15.00|16.00|15.00|15.00|15.00|15.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|110.11|108.57|111.13|117.82|128.11|171.32|0%|
|BlinkBlox|4.03|4.02|4.06|4.56|5.25|10.74|0%|
|Blink|4.56|4.07|4.65|4.76|4.85|8.64|0%|
|zap|20.48|19.96|20.73|22.75|26.31|38.57|0%|
|ByteNet|37.79|37.55|42.73|49.09|57.49|80.53|0%|
|Packet|50.25|50.02|56.91|67.60|79.11|109.32|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|41919.47|7.6|0%|
|BlinkBlox|0.69|4.9|0%|
|Blink|0.69|5.0|0%|
|zap|0.69|4.8|0%|
|ByteNet|0.69|4.6|0%|
|Packet|0.69|4.4|0%|
## [BooleansRandom](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/BooleansRandom.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|16.00|16.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|60.00|61.00|59.00|59.00|59.00|59.00|0%|
|Blink|36.00|40.00|33.00|32.00|32.00|31.00|0%|
|zap|26.00|27.00|25.00|25.00|25.00|22.00|0%|
|ByteNet|15.00|17.00|15.00|15.00|15.00|15.00|0%|
|Packet|15.00|16.00|15.00|15.00|15.00|15.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|29.40|25.90|34.03|39.38|44.43|60.96|0%|
|BlinkBlox|8.73|8.63|8.92|10.10|11.70|16.90|0%|
|Blink|20.52|17.82|24.43|28.35|30.24|44.16|0%|
|zap|34.42|33.73|34.61|34.77|36.99|51.85|0%|
|ByteNet|44.71|44.00|44.96|46.44|50.42|68.11|0%|
|Packet|77.52|77.18|87.49|90.63|95.45|166.63|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|3849.91|5.5|0%|
|BlinkBlox|128.53|9.4|0%|
|Blink|193.10|9.1|0%|
|zap|193.19|9.8|0%|
|ByteNet|193.37|9.4|0%|
|Packet|192.13|9.6|0%|
## [EntitiesRandom](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/EntitiesRandom.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|15.00|15.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|51.00|60.00|43.00|40.00|40.00|39.00|0%|
|Blink|22.00|24.00|21.00|21.00|21.00|19.00|0%|
|zap|22.00|24.00|22.00|22.00|22.00|20.00|0%|
|ByteNet|17.00|18.00|17.00|16.00|16.00|15.00|0%|
|Packet|15.00|17.00|15.00|15.00|15.00|15.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|115.57|108.85|129.64|137.93|146.34|247.82|0%|
|BlinkBlox|5.07|4.46|5.78|6.70|8.01|15.93|0%|
|Blink|5.00|4.49|5.13|5.23|5.55|9.45|0%|
|zap|20.35|19.85|20.60|23.01|23.62|32.57|0%|
|ByteNet|38.31|37.84|45.09|53.32|59.93|90.11|0%|
|Packet|53.06|50.20|57.22|72.46|80.23|118.69|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|40205.11|7.2|0%|
|BlinkBlox|603.90|10.5|0%|
|Blink|604.18|10.5|0%|
|zap|602.58|10.7|0%|
|ByteNet|603.79|10.6|0%|
|Packet|606.75|10.0|0%|