# Sleepace BM8701_2: BLE WiFi + server configuration with TLS, without the iOS SDK

Handoff spec for: kimi3
Target: WisefidoBle iOS app (Objective-C), device SleepBoard **BM8701-2** (`SLPDeviceType_BM8701_2 = 0x31`, BLE name `BM8722xxxxxxx`, 13 chars)
Status: protocol taken from Android SDK bytecode (javap only). It has **not yet been checked against a real device from iOS**. Items marked **UNVERIFIED** still need a device test.

---

## 1. Background / why

- The app configures BM8701_2 through the Sleepace iOS SDK:
  `-[SLPBleWifiConfig configPeripheral:deviceType:serverAddress:port:wifiName:password:completion:]`
  (`sdkSleepace/BLEWifiConfig.framework/Headers/SLPBleWifiConfig.h`, called from `WisefidoBle/SleepaceBleManager.m` ~line 502).
  This call takes one port and has **no TLS / portEncrypt option**. `MainViewController.m:658` already warns about this.
- The Android SDK (`wificonfigsdk.jar` + `sdkcore.jar`) has
  `WiFiConfigHelper.bleWiFiConfig(short deviceType, String btAddress, String serverIP, int serverPort, Boolean portEncrypt, byte[] ssidRaw, String pwd, String staticIp, String staticCode, String staticGateway, IResultCallback)`.
  For BM8701_2 it sends a server-address payload with **two port slots (plain and TLS)**.
- Goal: in Objective-C/CoreBluetooth, do exactly what the Android SDK does for BM8701_2. Only this one device type uses the new path. Every other device keeps the iOS SDK.

Key finding: BM8701_2 does **not** use the "BLE protocol" packet format (`WiFiConfigHelper$BlePacket`). That format is used only for EW201W / Nox2W / NoxSAW. BM8701_2 uses the **Sleepace TCP "SocketFrame" protocol tunnelled over BLE** (`com.sleepace.sdk.manager.socket.SocketFrame` / `SocketManager`). The frames are cut into 20-byte BLE writes.

---

## 2. Evidence map (where each fact comes from)

| Fact | Class / method (bytecode) |
|---|---|
| Public entry, UUID selection, scan, connect | `WiFiConfigHelper.bleWiFiConfig(S,String,String,I,Boolean,[B,String,String,String,String,IResultCallback)` |
| `isBleProtocol()` = EW201W or Nox2W or NoxSAW only (so BM8701_2 = false) | `WiFiConfigHelper.isBleProtocol()` |
| Message types per device: BM8701_2 -> `{514, 930, 928}` | `WiFiConfigHelper.getMsgType(DeviceType)`. BM8701_2 enum ordinal 27 maps through `$SWITCH_TABLE` to case 28, which branches to offset 201 |
| BM8701_2 type code 49 (0x31) | `DeviceType.<clinit>`: `new DeviceType("DEVICE_TYPE_BM8701_2", 27, 49, 0)` |
| Step order: sleep 500ms, getDeviceInfo, setNet, setWifi | `WiFiConfigHelper$5.run()` |
| Start of the flow on BLE CONNECTED | `WiFiConfigHelper$2.onStateChanged` -> `access$3` -> `bleWiFiConfig()` -> executor runs `$5` |
| BM8701_2 server payload (36 bytes, TLS slot) | `WiFiConfigHelper.setNet(S)`, branch `DeviceType.isBM8701_2` (offsets 404-630) |
| WiFi payload (120 bytes) | `WiFiConfigHelper.setWifi(S)` |
| DeviceInfo parse | `WiFiConfigHelper.getDeviceInfo(S)` (non-BLE-protocol branch) |
| Frame serialization, CRC32, end marker | `SocketFrame.frame2Byte`, `SocketFrame.createFrames`, `SocketFrame.createFrame`, `SocketFrame.createNewSerialCode` |
| Frame parsing | `SocketFrame.byte2Frame`, `SocketManager.handleData([B)` |
| Request/response wait, 3 s timeout, status check | `SocketManager.sendMsg2Server([B,B,S,S,String)`, `SocketManager.requestServer(...)` overloads |
| 20-byte BLE chunking | `WiFiConfigHelper.sendData([B)` (BLE branch) |
| Write and wait for write callback, 30 ms poll, 10 tries | `BleHelper.sendData([B,DeviceManager)`, `BleHelper$5.onCharacteristicWrite` |
| Notify enable via CCCD 0x2902 | `BleHelper.setCharacteristicNotification`, `BleHelper$5$1.run` |
| MTU (not requested by default) | `BleHelper.<init>` (mtu=20), `BleHelper$5.onConnectionStateChange` |
| Big-endian ints | `ByteUtil.short2byte`, `ByteUtil.int2byte`, `ByteUtil.byte2short`, `ByteUtil.byte2Int` |
| Seq matching | `DataPackBlockingQueue.addSendPack/offer/peek` (keyed by `seq.toString()`) |
| Result status codes | `CallbackData.<init>` (default -3), `isSuccess()` (status==0) |
| UUIDs FFE0/FFE4/FFE5/FFE9 also used by the iOS SDK | `strings` on `BluetoothManager.framework` and `ios_bm8701-2_demo/framework/BM8701_2.framework` |

---

## 3. BLE transport

### 3.1 GATT

`bleWiFiConfig` (non-EW201W branch) calls `BleHelper.initUUID(notifyService, notifyChar, writeService, writeChar)` with:

| Role | Service UUID | Characteristic UUID |
|---|---|---|
| Notify (device -> app) | `0000FFE0-0000-1000-8000-00805F9B34FB` (`FFE0`) | `0000FFE4-0000-1000-8000-00805F9B34FB` (`FFE4`) |
| Write (app -> device) | `0000FFE5-0000-1000-8000-00805F9B34FB` (`FFE5`) | `0000FFE9-0000-1000-8000-00805F9B34FB` (`FFE9`) |

- Notifications are turned on for FFE4: `setCharacteristicNotification(gc,true)` plus a write of `ENABLE_NOTIFICATION_VALUE` to descriptor `0x2902`. On iOS this is `setNotifyValue:YES forCharacteristic:`.
- The write and notify characteristics are in **two different services**. Discover both.

### 3.2 Connection sequence on Android (timing to copy)

1. Scan until the device with the given MAC is found. Stop the scan and connect (`WiFiConfigHelper$1.onLeScan`). On iOS you already have the peripheral identifier from the scan.
2. `onConnectionStateChange(CONNECTED)`. MTU is requested **only if** the app called `setMtu(>20)`. The default `mtu = 20`, so normally **no MTU request** is made. Then service discovery runs.
3. `onServicesDiscovered`: get both services and both characteristics. After a **200 ms** delay (`postDelayed(...,200)`), `BleHelper$5$1` enables notify on FFE4 and reports CONNECTED.
4. `WiFiConfigHelper$2.onStateChanged(CONNECTED)` starts `WiFiConfigHelper$5`. That runnable **sleeps 500 ms**, then runs the steps in section 5.

Android constants: connect timeout 10 s (`CONNECT_TIMEOUT=10000`), 3 connect retries, scan 6 s.

### 3.3 Writes

- `WiFiConfigHelper.sendData([B)` (BLE branch) cuts the **whole serialized frame** into chunks of **at most 20 bytes**. This is fixed and does not depend on MTU. Each chunk goes through `BleHelper.sendData`.
- `BleHelper.sendData` sets the value and calls `writeCharacteristic`. It repeats every **30 ms**, up to **10** times, until `onCharacteristicWrite(status==0)` sets `mSendOk`. In effect: one chunk is in flight at a time, and the next is sent after the write callback.
- Android does not set an explicit write type, so `BluetoothGattCharacteristic`'s default applies. That is "no response" if the characteristic has the WRITE_NO_RESPONSE property, otherwise "with response".
  **iOS:** if `FFE9.properties & CBCharacteristicPropertyWriteWithoutResponse`, use `CBCharacteristicWriteWithoutResponse` and pace with `canSendWriteWithoutResponse` / `peripheralIsReadyToSendWriteWithoutResponse:`. Otherwise use `WithResponse` and wait for `didWriteValueForCharacteristic:`. **UNVERIFIED** which property FFE9 actually exposes. Log `characteristic.properties` on first connect.
- Recommendation: keep 20-byte chunks on iOS too, even if `maximumWriteValueLengthForType:` is larger. The firmware is only known to work with 20-byte writes.

---

## 4. Frame format (SocketFrame over BLE)

All multi-byte integers are **big-endian** (`ByteUtil.short2byte`: `[v>>8, v]`; `int2byte`: `[v>>24, v>>16, v>>8, v]`).

### 4.1 Request frame (what we send)

`frame2Byte` writes the fields in this order:

| Offset | Size | Field | Value for our requests | Source |
|---|---|---|---|---|
| 0 | 1 | versionCode | `0x00` | `createFrame`: `setVersonCode(0)` |
| 1 | 1 | from | `0x01` | static `SocketFrame.FromCode` = 1. `setFromCode` is never called by either jar or the demo |
| 2 | 4 | gallery (channel) | `00 00 00 00` | `requestServer` passes `""`, so `TextUtils.isEmpty` gives gallery=0 |
| 6 | 1 | frameType | `0x02` (request) | `requestServer(...)` -> `sendMsg2Server(data, (byte)2, msgType, deviceType, "")` |
| 7 | 2 | frameCount | `00 01` | single fragment |
| 9 | 2 | frameNum (index) | `00 00` | first (only) fragment |
| 11 | 2 | frameSeq | `00 01`, `00 02`, ... | `createNewSerialCode()`: static short, `++`, reset to 1 if negative, so the first value is 1 |
| (13) | (2) | specialIdentify `0xC350` | **omitted** | only written if `deviceType != 0`. BM8701_2 calls pass deviceType 0 (`requestServer([B,S)` / `([B,S,S)` with 0) |
| (15) | (2) | deviceType | **omitted** | same |
| 13 | 2 | msgType | e.g. `03 A2` | |
| 15 | N | content | payload | |
| 15+N | 4 | CRC32 | see 4.3 | over bytes `[0, 15+N)` |
| 19+N | 4 | end marker | `24 5F 40 2D` = ASCII `"$_@-"` | `SocketFrame.FRAME_END` |

Total length = **23 + N** (`SocketFrame.getPakcageSize()` returns `23 + content.length`).

Frame types (from `SocketManager.handleData` / `sendMsg2Server`): `0` = ACK, `1` = POST (device push; msgType 0 = heartbeat), `2` = REQUEST, `3` = RESPONSE.

Fragmentation at frame level: `createFrames` scans the content for the 4-byte sequence `"$_@-"` and splits the content into several frames there (frameCount/frameNum). Our payloads never contain that sequence unless the user puts `$_@-` in SSID, password or host. **Reject such input** rather than copy that odd split logic. The exact split offset (`i-2`) looks buggy. **UNVERIFIED** how the firmware handles it.

### 4.2 Response frame (what we receive)

`SocketFrame.byte2Frame(bytes)`:

- `[0]` version, `[1]` from, `[2..5]` gallery, `[6]` frameType, `[7..8]` frameCount, `[9..10]` frameNum, `[11..12]` frameSeq.
- Read u16 at `[13]`:
  - if it is `0xC350` (short -15536): `[15..16]` deviceType, `[17..18]` msgType, content = `[19 .. len-8)` (**19-byte header**)
  - else: `[13..14]` msgType, content = `[15 .. len-8)` (**15-byte header**)
- `msgStatus` = u16 at `content[0..1]`. **The status is the first 2 bytes of the content**, so it is part of the content.
- Last 8 bytes: CRC32 (BE u32) + `"$_@-"`.

Your parser must accept both header variants. **UNVERIFIED** which one BM8701_2 uses in its responses.

### 4.3 CRC

`java.util.zip.CRC32`: standard CRC-32 (IEEE 802.3 / zlib). Reflected polynomial `0xEDB88320`, init `0xFFFFFFFF`, final XOR `0xFFFFFFFF`, reflected in and out. Check value: `crc32("123456789") = 0xCBF43926`.
Covered bytes: **everything from offset 0 up to the end of the content** (header + content). The CRC itself and the end marker are not covered. Written big-endian.
On receive (`SocketManager.handleData`): CRC32 over `[0, len-8)` is compared with BE u32 at `len-8`. On mismatch the buffer is discarded.

iOS: `#include <zlib.h>`, `crc32(crc32(0L, Z_NULL, 0), bytes, len)` (link `libz.tbd`), or the bitwise version:

```
uint32_t crc32_ieee(const uint8_t *p, size_t n) {
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) {
        c ^= p[i];
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (uint32_t)-(int32_t)(c & 1));
    }
    return c ^ 0xFFFFFFFFu;
}
```

(The CRC8 table in `com.sleepace.sdk.manager.CRC` is **not** used on this path.)

### 4.4 Receive reassembly (Android behaviour, and what to do on iOS)

`SocketManager.handleData(byte[] notification)`:
- Appends bytes to a 1024-byte buffer. After each byte equal to `'-'`, it checks whether the previous 3 bytes **of the same notification** are `$_@`. Android quirk: an end marker split across two notifications is not detected. On iOS, search the **accumulated** buffer for `"$_@-"`.
- On a marker: if length <= 8, drop. Otherwise check the CRC (drop the buffer on mismatch), then `byte2Frame`.
- Multi-fragment responses (`frameCount > 1`) are merged by appending contents in order until `frameNum + 1 == frameCount`. Implement this for safety. Our responses are expected to be single-fragment.
- When complete: type 1 is POST (msgType 0 means heartbeat, and the app answers with `getResponeHeartFrames(seq)`; ignore it during config). Type 2 is a request from the device (ignore). **Any other type (0 ACK, 3 RESPONSE)** is put in the wait-queue keyed by `frameSeq`.
- iOS: after a marker, if the CRC fails, drop bytes up to and including the marker and keep scanning. Note the CRC bytes could by chance contain `"$_@-"` (very unlikely). If the CRC fails at the first marker, you can also try the next one.

### 4.5 Request/response matching and success rule

`SocketManager.sendMsg2Server([B data, B type=2, S msgType, S devType=0, String "")`:
1. Build the frame with a new seq, register the seq, send it (chunked).
2. Poll every 10 ms for up to **3000 ms** for a received frame with the **same frameSeq** (as a string key; msgType is not checked).
3. When found: `st = u16(content[0..1])`.
   - `st == 0`: status 0 (success). If frameType==3, `parseRespone` runs. If frameType==0 (ACK), `parseAck` runs (no-op), and it is **still success**.
   - `st != 0`: status = st (failure).
   - If the content is shorter than 2 bytes, Java throws inside the try. The default status -3 stays, so it is a failure.
4. Nothing within 3 s: status -2 (timeout). Not connected: -1.

So on iOS: **success = a frame with matching seq, a valid CRC, and content[0..1] == 0x0000, received within 3 s.** Optionally also check that msgType echoes the request. Android does not check this, so log a mismatch instead of failing.

---

## 5. Message sequence for BM8701_2

`getMsgType(BM8701_2)` returns `[0x0202 (514), 0x03A2 (930), 0x03A0 (928)]`. Constants in `SocketFrame`: `REQUEST_SET_SERVER_ADDRESS = 930`, `REQUEST_SET_WIFI_CONFIG = 928`. 514 has no named constant; EW202W_DEVICE_INFO is 518.

`WiFiConfigHelper$5.run()`:

| # | Step | msgType | Content | Retry | Failure |
|---|---|---|---|---|---|
| 0 | wait | - | - | sleep 500 ms after CONNECTED (+200 ms after discovery in BleHelper) | - |
| 1 | Get device info | `0x0202` | empty (0 bytes) | up to 3 attempts, 100 ms sleep between, each with a 3 s timeout | abort with -3 |
| 2 | Set server address | `0x03A2` | 36 bytes (5.2) | none | abort with -3 |
| 3 | Set WiFi | `0x03A0` | 120 bytes (5.3) | none | -3 |
| 4 | Done | - | - | result = DeviceInfo(deviceId, version) | - |

- Step 2 is skipped only for Nox2W (not our device).
- If `ssidRaw == null`, step 3 is skipped and the result is success after step 2 ("server only" mode). Note it for later, but the app always sends WiFi for SleepBoard.
- After success, `onResultCallback` does **not** call `disconnect()` for `config_wifi_ble`. Android leaves the link up. iOS: cancel the connection after success, e.g. after 300-500 ms. **UNVERIFIED** whether the device reboots or drops the link by itself.
- Android error codes (callback status): -1 disconnected, -2 timeout, -3 failed, -4 Bluetooth off, -5 parameter error.

### 5.1 0x0202 Get device info: response content (BM8701_2)

From `getDeviceInfo(S)` (non-BLE branch). The `+14` skip applies only to Z4TW/SN913E/EW202W/BG002/Z400TWP3, **not** BM8701_2:

| Content offset | Size | Meaning |
|---|---|---|
| 0 | 2 | status (0 = OK) |
| 2 | 13 | deviceId, ASCII, e.g. `BM87224601903` (same as the BLE name) |
| 15 | 1 | (padding/terminator; skipped: offset += 14) |
| 16 | 2 | u16, read but **unused** (meaning UNVERIFIED; maybe hardware version) |
| 18 | 2 | u16 firmware version x 100 -> `String.format("%.2f", v*0.01)` |

Minimum content length 20. If the content is shorter, treat the device info as unavailable. Android would throw here and fail the step. iOS may tolerate it, but log it.

### 5.2 0x03A2 Set server address: BM8701_2 payload (36 bytes)

From `setNet(S)` `isBM8701_2` branch:

| Offset | Size | Field |
|---|---|---|
| 0 | 32 | server address, `getBytes("UTF-8")`, zero-padded |
| 32 | 2 | **plain TCP port** (BE u16), `00 00` when TLS |
| 34 | 2 | **TLS port** (BE u16), `00 00` when not TLS |

- `portEncrypt == true`: `[32..33] = 00 00`, `[34..35] = port`.
- `portEncrypt == false`: `[32..33] = port`, `[34..35] = 00 00`.
- Android copies the address with `System.arraycopy(addr, 0, buf, 0, addr.length)` and **no length check**. 33-36 bytes would be overwritten by the ports, and more than 36 throws. **iOS: reject addresses > 32 bytes UTF-8**. 31 is recommended so a NUL terminator stays; whether the firmware needs the NUL is **UNVERIFIED**.
- The port is passed through `(short)port`, so the bytes equal a u16 1..65535.
- Android logs this payload: `BM8701_2-setNet------data:` + `Arrays.toString(data)` (signed decimal).
- `portEncrypt` is a `Boolean` object. Android NPEs if null. The demo passes `false` for "non-TLS".

For comparison only (not BM8701_2): the generic fallback is 34 bytes (addr 32 + port 2), and M8701W uses 259 bytes. BM8701 (0x8099) uses the 162-byte layout. The BM8701_2 layout is unique to it.

### 5.3 0x03A0 Set WiFi payload (120 bytes)

From `setWifi(S)`. BM8701_2 is not `isBleProtocol`, so it is sent as `requestServer(data, 928, 0)` with no 1-byte prefix (that prefix is Nox2W/NoxSAW only):

| Offset | Size | Field |
|---|---|---|
| 0 | 33 | SSID raw bytes (<= 32, enforced by `bleWiFiConfig`: >32 gives -5), zero-padded |
| 33 | 1 | password flag / "encryption": `0` if password empty, else `1` |
| 34 | 65 | password `getBytes()` (UTF-8 on Android), zero-padded. **No length check on Android; iOS: enforce <= 64 bytes** |
| 99 | 1 | IP type: `0` = DHCP, `1` = static |
| 100 | 4 | static IP (4 octets) or zeros |
| 104 | 4 | subnet mask ("staticCode") or zeros |
| 108 | 4 | gateway or zeros |
| 112 | 4 | zeros (reserved, probably DNS1; UNVERIFIED) |
| 116 | 4 | zeros (reserved, probably DNS2; UNVERIFIED) |

- DHCP is chosen when `staticIp` is empty, `null` or `""`. Then `[99]=0` and `[100..119]` are all zero.
- Static: `[99]=1`, then `ipToByteArray(ip)`, `ipToByteArray(mask)`, `ipToByteArray(gateway)`, then 8 zero bytes. `ipToByteArray("a.b.c.d")` = `[a,b,c,d]`.
- SSID bytes: Android uses the raw octets from `WifiInfo.getWifiSsid().getOctets()`. iOS: `[ssid dataUsingEncoding:NSUTF8StringEncoding]`.

---

## 6. Worked example

Inputs: server `app.wisefido.com`, port `8443`, TLS on, SSID `TestWiFi`, password `12345678`, DHCP. Seq numbers 1, 2, 3 as in a fresh Android process. Generated with zlib CRC32 per section 4.

**Server payload (36 bytes)**
```
61 70 70 2E 77 69 73 65 66 69 64 6F 2E 63 6F 6D   "app.wisefido.com"
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00   pad to 32
00 00                                             plain port = 0
20 FB                                             TLS port = 8443
```
Android SdkLog for the same input:
```
BM8701_2-setNet------data:[97, 112, 112, 46, 119, 105, 115, 101, 102, 105, 100, 111, 46, 99, 111, 109, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32, -5]
```

**Frame 1: get device info (seq 1, 0x0202, no content), 23 bytes**
```
00 01 00 00 00 00 02 00 01 00 00 00 01 02 02 1F A7 A8 3A 24 5F 40 2D
```
BLE writes: `[00 01 00 00 00 00 02 00 01 00 00 00 01 02 02 1F A7 A8 3A 24]`, `[5F 40 2D]`

**Frame 2: set server (seq 2, 0x03A2, 36 bytes), 59 bytes**
```
00 01 00 00 00 00 02 00 01 00 00 00 02 03 A2
61 70 70 2E 77 69 73 65 66 69 64 6F 2E 63 6F 6D 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 20 FB
7E 17 26 E1   (CRC32)
24 5F 40 2D
```
BLE writes (20/20/19):
```
00 01 00 00 00 00 02 00 01 00 00 00 02 03 A2 61 70 70 2E 77
69 73 65 66 69 64 6F 2E 63 6F 6D 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 20 FB 7E 17 26 E1 24 5F 40 2D
```

**Frame 3: set WiFi (seq 3, 0x03A0, 120 bytes), 143 bytes**
Content: `54 65 73 74 57 69 46 69` ("TestWiFi") + 25 x `00` | `01` | `31 32 33 34 35 36 37 38` ("12345678") + 57 x `00` | `00` (DHCP) | 20 x `00`
CRC32 = `36 70 93 96`
BLE writes:
```
00 01 00 00 00 00 02 00 01 00 00 00 03 03 A0 54 65 73 74 57
69 46 69 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 01 31 32 33 34 35 36 37 38 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 36 70 93 96 24
5F 40 2D
```

Static IP variant (192.168.1.50 / 255.255.255.0 / gw 192.168.1.1), content bytes 99..119:
`01 C0 A8 01 32 FF FF FF 00 C0 A8 01 01 00 00 00 00 00 00 00 00` (the CRC changes accordingly).

Plain-TCP variant (TLS off, port 29010 = 0x7152): server payload bytes 32..35 = `71 52 00 00`.

Example of a well-formed OK response to seq 2. This is a **synthetic test vector**; the real device `from` byte or header variant may differ:
`00 01 00 00 00 00 03 00 01 00 00 00 02 03 A2 00 00 5B 97 67 EE 24 5F 40 2D`

---

## 7. iOS side findings

- `SLPDeviceType_BM8701_2 = 0x31` (`SLPCommon.framework/Headers/SLPDataTransferDef.h:84`) equals the Android type 49. The app maps the name prefix `BM8722` to `"BM8701_2"` (`SleepaceBleManager.m` `getDeviceType:`).
- The `BLEWifiConfig.framework` public API (`SLPBleWifiConfig.h`) has no TLS parameter. Internal classes (from `nm`): `BleConfigServerAddress`, `BleConfigWifiName`, `BleConfigGetDeviceInfo`, `SLPBleWifiConfigTCPProtocolEntity`. This matches the TCP-frame-over-BLE design above.
- `BluetoothManager.framework` does expose a generic send: `-[SLPBLEManager sendPacket:(SLPBLEBaseSendPacket *) peripheral:]`. Packet classes live in **PrivateHeaders**: `SLPBLEBaseSendPacket` (framType, messageType, sequence, content, timeout, completion), `SLPBLESendPacketV_0..3`. `V_2/V_3` have `channelID`, which is likely the "gallery" field. Parsers: `SLPBLEParserOriginal/Promotional/Special`. **Do not build on this**: the headers are private, undocumented, and give no control over the 36-byte layout semantics or seq. Using them would mean reverse-engineering the static lib (out of scope). It is mentioned only as a possible fallback (UNVERIFIED).
- Both the iOS SDK binaries and the BM8701_2 demo framework contain `0xFFE0`, `0xFFE4`, `0XFFE5`, `0xFFE9`. This matches the Android UUIDs.
- **CBPeripheral ownership:** the app scans with the SDK (`[SLPBLEManager scanBluetoothWithTimeoutInterval:...]`). The cached `CBPeripheral` objects belong to the **SDK's internal `CBCentralManager`**, whose delegate is the SDK. Do not set `peripheral.delegate` on those objects or connect them from another central. The new configurator should own a **private `CBCentralManager`** and get its own handle with `retrievePeripheralsWithIdentifiers:@[uuid]`. Make sure the SDK is not connected to the same device first: call `[SLPBLESharedManager disconnectPeripheral:timeout:completion:]` and stop the SDK scan (`stopAllPeripheralScan`).
- `SleepaceBleManager.h` declares `<CBCentralManagerDelegate, CBPeripheralDelegate>` and has an unused `cbManager` property. Keep the new code in a separate class so the SDK path is untouched.
- The TLS switch is not passed down yet. `MainViewController.m:647` takes `serverProtocol` from `parseProtocolAndPort` (usually `"tcp"`). Lines 658-660 only show a note when `tlsSwitch.isOn`. Pass `@"tls"` as `serverProtocol` when `tlsSwitch.isOn`, or add an explicit `BOOL tls` parameter. The constants `kDeviceServerModeTls = @"tls"` and `kDeviceServerModeTcp = @"tcp"` already exist in `DeviceServerRules.m`.

---

## 8. Proposed Objective-C design

### 8.1 Interface

```objc
// SleepaceBm8701TlsConfigurator.h
#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const SleepaceBm8701ErrorDomain;
typedef NS_ERROR_ENUM(SleepaceBm8701ErrorDomain, SleepaceBm8701Error) {
    SleepaceBm8701ErrorBluetoothOff   = -4,   // mirrors Android codes
    SleepaceBm8701ErrorParameter      = -5,
    SleepaceBm8701ErrorDisconnected   = -1,
    SleepaceBm8701ErrorTimeout        = -2,
    SleepaceBm8701ErrorFailed         = -3,   // device status != 0 or bad frame
    SleepaceBm8701ErrorServiceMissing = -10,  // FFE0/FFE5 or FFE4/FFE9 not found
    SleepaceBm8701ErrorConnectFailed  = -11,
    SleepaceBm8701ErrorCancelled      = -12,
};

typedef NS_ENUM(NSInteger, SleepaceBm8701Step) {
    SleepaceBm8701StepConnecting, SleepaceBm8701StepGetDeviceInfo,
    SleepaceBm8701StepSetServer, SleepaceBm8701StepSetWiFi, SleepaceBm8701StepDone,
};

/// completion info keys: @"deviceId" (NSString), @"version" (NSString "%.2f"),
/// @"failedStep" (NSNumber SleepaceBm8701Step), @"deviceStatus" (NSNumber u16, if device rejected)
typedef void (^SleepaceBm8701Completion)(BOOL success, NSDictionary *info, NSError * _Nullable error);

@interface SleepaceBm8701TlsConfigurator : NSObject

- (instancetype)initWithPeripheralIdentifier:(NSUUID *)identifier;

/// Full Android-equivalent flow: connect -> 0x0202 -> 0x03A2 -> 0x03A0 -> disconnect.
/// staticIp/mask/gateway: all nil => DHCP. ssid nil => server-only (Android skips setWifi).
- (void)configureWithServerAddress:(NSString *)serverAddress
                              port:(uint16_t)port
                               tls:(BOOL)tls
                              ssid:(nullable NSString *)ssid
                          password:(nullable NSString *)password
                          staticIp:(nullable NSString *)staticIp
                        subnetMask:(nullable NSString *)subnetMask
                           gateway:(nullable NSString *)gateway
                          progress:(nullable void (^)(SleepaceBm8701Step step))progress
                        completion:(SleepaceBm8701Completion)completion;

- (void)cancel;

#pragma mark - Pure functions (unit-testable, no BLE)
+ (NSData *)frameWithMessageType:(uint16_t)msgType sequence:(uint16_t)seq content:(NSData *)content;
+ (nullable NSData *)serverPayloadWithAddress:(NSString *)address port:(uint16_t)port tls:(BOOL)tls error:(NSError **)error;
+ (nullable NSData *)wifiPayloadWithSSID:(NSData *)ssid password:(nullable NSString *)password
                                staticIp:(nullable NSString *)ip mask:(nullable NSString *)mask
                                 gateway:(nullable NSString *)gw error:(NSError **)error;
+ (uint32_t)crc32:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
```

### 8.2 Reference implementation of the pure parts

```objc
static const uint8_t kFrameEnd[4] = {'$','_','@','-'};

static void PutU16BE(NSMutableData *d, uint16_t v) { uint8_t b[2] = {v >> 8, v & 0xFF}; [d appendBytes:b length:2]; }
static void PutU32BE(NSMutableData *d, uint32_t v) { uint8_t b[4] = {v>>24, v>>16, v>>8, v}; [d appendBytes:b length:4]; }

+ (NSData *)frameWithMessageType:(uint16_t)msgType sequence:(uint16_t)seq content:(NSData *)content {
    NSMutableData *f = [NSMutableData data];
    uint8_t vf[2] = {0x00 /*version*/, 0x01 /*from*/};
    [f appendBytes:vf length:2];
    PutU32BE(f, 0);           // gallery
    uint8_t type = 0x02;      // request
    [f appendBytes:&type length:1];
    PutU16BE(f, 1);           // frameCount
    PutU16BE(f, 0);           // frameNum
    PutU16BE(f, seq);         // frameSeq
    PutU16BE(f, msgType);     // (no 0xC350/deviceType: deviceType == 0)
    [f appendData:content ?: [NSData data]];
    PutU32BE(f, [self crc32:f]);
    [f appendBytes:kFrameEnd length:4];
    return f;
}

+ (NSData *)serverPayloadWithAddress:(NSString *)address port:(uint16_t)port tls:(BOOL)tls error:(NSError **)error {
    NSData *a = [address dataUsingEncoding:NSUTF8StringEncoding];
    if (a.length == 0 || a.length > 32 || port == 0) { /* set ErrorParameter */ return nil; }
    NSMutableData *p = [NSMutableData dataWithLength:36];
    uint8_t *b = p.mutableBytes;
    memcpy(b, a.bytes, a.length);
    uint8_t *slot = tls ? b + 34 : b + 32;      // plain @32, TLS @34; other slot stays 00 00
    slot[0] = port >> 8; slot[1] = port & 0xFF;
    return p;
}

+ (NSData *)wifiPayloadWithSSID:(NSData *)ssid password:(NSString *)password
                       staticIp:(NSString *)ip mask:(NSString *)mask gateway:(NSString *)gw error:(NSError **)error {
    NSData *pw = [password ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
    if (ssid.length == 0 || ssid.length > 32 || pw.length > 64) { /* ErrorParameter */ return nil; }
    NSMutableData *p = [NSMutableData dataWithLength:120];
    uint8_t *b = p.mutableBytes;
    memcpy(b, ssid.bytes, ssid.length);         // [0..32]
    b[33] = pw.length ? 1 : 0;
    memcpy(b + 34, pw.bytes, pw.length);        // [34..98]
    if (ip.length) {                            // static: require mask + gateway too
        b[99] = 1;
        if (!ParseIPv4(ip, b + 100) || !ParseIPv4(mask, b + 104) || !ParseIPv4(gw, b + 108)) { /* ErrorParameter */ return nil; }
    } // else DHCP: b[99]=0, [100..119]=0
    return p;
}
```

Also reject any SSID, password or host whose bytes contain `"$_@-"` (section 4.1).

### 8.3 BLE state machine (implementation notes)

1. `centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:serialQueue]`. Wait for `PoweredOn` (otherwise fail with -4). `peripheral = [central retrievePeripheralsWithIdentifiers:@[identifier]].firstObject`. If it is nil, do a short scan filtered by name. `connectPeripheral:` with a 10 s timeout.
2. `discoverServices:@[FFE0, FFE5]`, then `discoverCharacteristics:@[FFE4]` on FFE0 and `@[FFE9]` on FFE5. A missing one gives -10.
3. `setNotifyValue:YES forCharacteristic:FFE4`. Wait for `didUpdateNotificationStateForCharacteristic:`, then **200 + 500 ms** (Android timing).
4. Send queue: for each frame, split into 20-byte chunks. Write type per section 3.3. Send the next chunk after `didWriteValueForCharacteristic:` (with-response) or when `canSendWriteWithoutResponse` (without).
5. Receive: `didUpdateValueForCharacteristic:` on FFE4 appends to `rxBuffer`. Extract frames per section 4.4. Deliver a frame whose `frameSeq == pendingSeq` to the pending step. Ignore other seqs and POST frames.
6. Per-request timer of **3.0 s**. Step 1 is retried up to 3 times with 100 ms gaps (use a **new seq** on each retry, as Android does). Steps 2 and 3: one attempt.
7. Sequence counter: per configurator instance, starting at 1 and incrementing per frame. Android uses a process-global counter, so its first frame is 1 only in a fresh process. The device should not care. **UNVERIFIED** whether it requires anything about seq.
8. On success or failure: `cancelPeripheralConnection:` (after ~300-500 ms on success), invalidate timers, call the completion **once** on the main queue. A disconnect during the flow gives -1.
9. Log every TX frame and RX notification as hex, and the FFE9 properties, with a `[BM8701TLS]` prefix to compare against Android (section 10).

### 8.4 Hooking into `SleepaceBleManager` (BM8701_2 only)

In `-configureDevice:wifiSsid:wifiPassword:serverAddress:serverPort:serverProtocol:completion:` (`SleepaceBleManager.m` ~line 388), after the existing validation and the config timer setup:

```objc
SLPDeviceTypes deviceType = [self getSLPDeviceType:device.deviceType];
BOOL wantsTls = [[serverProtocol lowercaseString] isEqualToString:kDeviceServerModeTls];   // "tls"

if (deviceType == SLPDeviceType_BM8701_2 && serverAddress.length && serverPort > 0 && wantsTls) {
    [_bleManager stopAllPeripheralScan];
    // ensure SDK central is not holding the link
    [SLPBLESharedManager disconnectPeripheral:_currentPeripheral timeout:2.0 completion:^(SLPBLEDisconnectReturnCodes code, NSInteger hid) {
        self.bm8701Configurator = [[SleepaceBm8701TlsConfigurator alloc]
            initWithPeripheralIdentifier:self->_currentPeripheral.identifier];
        [self.bm8701Configurator configureWithServerAddress:serverAddress port:(uint16_t)serverPort tls:YES
                                  ssid:wifiSsid password:wifiPassword
                              staticIp:nil subnetMask:nil gateway:nil progress:nil
                            completion:^(BOOL ok, NSDictionary *info, NSError *err) {
            // map to the existing wrappedCompletion contract:
            // status = ok ? SLPDataTransferStatus_Succeed : (err.code == -2 ? SLPDataTransferStatus_TimeOut : SLPDataTransferStatus_Failed)
            wrappedCompletion(ok ? SLPDataTransferStatus_Succeed : SLPDataTransferStatus_Failed, info);
        }];
    }];
    return;
}
// else: existing SLPBleWifiConfig path unchanged
```

- Add `@property (nonatomic, strong) SleepaceBm8701TlsConfigurator *bm8701Configurator;` to keep it alive.
- The existing 30 s `configTimer` stays as the outer guard. On timeout, also call `[self.bm8701Configurator cancel]`.
- `MainViewController`: pass `serverProtocol = self.tlsSwitch.isOn ? kDeviceServerModeTls : kDeviceServerModeTcp` for SleepBoard, and drop the note at lines 658-660 once this works.
- Optional, after the device test passes: route **non-TLS** BM8701_2 through the configurator too (`tls:NO`). That gives one code path for this device. Keep the SDK path for every other device type.
- `handleDeviceDisconnected:` listens to SDK notifications only. The configurator reports its own disconnects through its completion.

---

## 9. Device-type specific notes (BM8701_2 vs others), from bytecode

| Aspect | BM8701_2 | Others |
|---|---|---|
| Transport frame | SocketFrame (TCP format) over BLE | EW201W/Nox2W/NoxSAW use `BlePacket` (CommonReq, frameType byte 3 head) |
| UUIDs | FFE0/FFE4 + FFE5/FFE9 | EW201W: AE00 service, AE02 notify, AE01 write |
| msgTypes | 0x0202 / 0x03A2 / 0x03A0 | e.g. EW202W 518/5378/5376; M8701W 518/5683/5680; Z-series 17/46/37 |
| Server payload | 36 B: addr32 + plainPort + tlsPort | generic 34 B; M8701W 259 B; BM8701/Z4TW/M600/M800/BG001A/SN913E/FH601W/EW202W 162 B; NoxSAW 100 B (BLE protocol) |
| Uses `portEncrypt` | **yes (only BM8701_2)** | ignored |
| DeviceInfo parse | deviceId at content+2 (no +14 skip) | +14 skip for Z4TW/SN913E/EW202W/BG002/Z400TWP3 |
| WiFi payload prefix byte | none | Nox2W/NoxSAW prepend `0x01` |
| SSID >32 check | yes | skipped for M901L |

---

## 10. Test plan

### 10.1 Unit tests (no hardware)
1. `crc32("123456789") == 0xCBF43926`.
2. `frameWithMessageType:0x0202 sequence:1 content:empty` equals frame 1 in section 6 byte for byte. The same for frames 2 and 3 with the section 6 inputs.
3. `serverPayload` TLS on/off puts the port in the correct slot. An address of 33 bytes gives an error.
4. `wifiPayload` DHCP and static variants (section 6 tail bytes). SSID 33 bytes gives an error. Password 65 bytes gives an error.
5. Parser: feed the section 6 synthetic OK response split across 2 notifications at every split point. It must yield 1 frame, seq 2, status 0. A flipped CRC byte must yield nothing. Also test a `0xC350` extended header.

### 10.2 Android reference capture (ground truth)
Run `BleConfigSdkDemo` against the same BM8701_2 with identical inputs (TLS on, 8443) and collect `SdkLog`/logcat:
- `BM8701_2-setNet------ipbytes:...,port:8443` and `BM8701_2-setNet------portEncrypt:true`
- `BM8701_2-setNet------data:[...]`: must equal the iOS server payload (signed decimal). See section 6.
- `WiFiConfigHelper sendData:[...]`: logs the **full frame before chunking** for each request. Compare with the iOS TX hex. Only `frameSeq` (bytes 11-12) and the CRC may differ.
- `SocketManager handleData len:..,data:[...]`: the **raw notifications from the device**. Use these to settle the UNVERIFIED response details: header variant, `from` byte, frameType 0 vs 3, content length of 0x0202.
- `getMsgType` log `[514, 930, 928]` and `device info:` / `setNet:` / `setWiFi:` CallbackData lines.

### 10.3 iOS on-device
1. Log the FFE9 properties, then the full TX/RX hex for one run with TLS on (8443) and one with TLS off (29010).
2. Check the server side: with TLS, the device must open a TLS connection to `app.wisefido.com:8443`. Without TLS, it must connect plain to the plain port.
3. Negative tests: wrong WiFi password (the config may still "succeed", because the protocol only acks storage; **UNVERIFIED**), device out of range during step 2 (expect -1/-2), Bluetooth off (-4).
4. Regression: non-BM8701_2 SleepBoard devices still configure through the SDK path.

---

## 11. Could NOT be determined with certainty (UNVERIFIED)

1. **Response frame details from the real device**: header variant (15 vs 19 bytes with `0xC350`+deviceType), `from` byte value, whether the device replies with frameType 3 (RESPONSE) or 0 (ACK) for 0x03A2/0x03A0. The Android code accepts both, and so should iOS.
2. **Content length/meaning of the 0x0202 response** beyond the parsed fields. Offset 16 (u16) is read and discarded by Android, so its meaning is unknown.
3. **FFE9 write type** (with or without response). The Android default depends on the characteristic properties, which are not visible in the jar.
4. Whether the firmware needs a **NUL terminator** in the 32-byte host field. Android allows exactly 32 bytes with no NUL.
5. Whether the firmware checks **frameSeq** or the `from` byte, or needs `gallery == 0`. Android always sends from=1, gallery=0, process-global seq starting at 1.
6. Meaning of WiFi payload bytes **112..119** (always zero on Android; probably DNS) and whether the firmware reads byte 33 as an "encryption type".
7. Post-success behaviour: whether the device reboots or disconnects by itself. Android does not disconnect after `config_wifi_ble`.
8. Whether the device works at MTU > 23 / chunks > 20 bytes. Android never requests MTU on this path by default.
9. Whether the iOS SDK's private `SLPBLEManager sendPacket:peripheral:` + `SLPBLESendPacketV_2` could send these frames. Not analysed (static lib, private headers). Not recommended.
10. Behaviour when the content contains `"$_@-"`. Android's `createFrames` split looks buggy, so reject such input.
11. The exact SSID bytes the firmware expects for non-ASCII SSIDs. Android sends raw octets; iOS will send UTF-8.
