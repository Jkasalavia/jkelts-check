import ctypes
import json
import sys


FILE_MAP_READ = 0x0004
SENSOR_TYPE_TEMP = 1
MAP_NAME = "Global\\HWiNFO_SENS_SM2"


class Header(ctypes.Structure):
    _pack_ = 1
    _fields_ = [
        ("signature", ctypes.c_uint32),
        ("version", ctypes.c_uint32),
        ("revision", ctypes.c_uint32),
        ("poll_time", ctypes.c_int64),
        ("sensor_offset", ctypes.c_uint32),
        ("sensor_element_size", ctypes.c_uint32),
        ("sensor_count", ctypes.c_uint32),
        ("reading_offset", ctypes.c_uint32),
        ("reading_element_size", ctypes.c_uint32),
        ("reading_count", ctypes.c_uint32),
        ("polling_period", ctypes.c_uint32),
    ]


class Sensor(ctypes.Structure):
    _pack_ = 1
    _fields_ = [
        ("sensor_id", ctypes.c_uint32),
        ("sensor_instance", ctypes.c_uint32),
        ("name_orig", ctypes.c_char * 128),
        ("name_user", ctypes.c_char * 128),
    ]


class Reading(ctypes.Structure):
    _pack_ = 1
    _fields_ = [
        ("reading_type", ctypes.c_uint32),
        ("sensor_index", ctypes.c_uint32),
        ("reading_id", ctypes.c_uint32),
        ("label_orig", ctypes.c_char * 128),
        ("label_user", ctypes.c_char * 128),
        ("unit", ctypes.c_char * 16),
        ("value", ctypes.c_double),
        ("value_min", ctypes.c_double),
        ("value_max", ctypes.c_double),
        ("value_avg", ctypes.c_double),
    ]


def clean(raw):
    return bytes(raw).split(b"\0", 1)[0].decode("mbcs", errors="ignore").strip()


def status_for(celsius):
    if celsius >= 90:
        return "CRITICAL"
    if celsius >= 80:
        return "WARNING"
    return "OK"


def main():
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenFileMappingW.argtypes = [ctypes.c_uint32, ctypes.c_bool, ctypes.c_wchar_p]
    kernel32.OpenFileMappingW.restype = ctypes.c_void_p
    kernel32.MapViewOfFile.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_size_t,
    ]
    kernel32.MapViewOfFile.restype = ctypes.c_void_p
    kernel32.UnmapViewOfFile.argtypes = [ctypes.c_void_p]
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]

    mapping = kernel32.OpenFileMappingW(FILE_MAP_READ, False, MAP_NAME)
    if not mapping:
        print(json.dumps({"available": False, "reason": "HWiNFO shared memory is not available"}))
        return 2

    view = kernel32.MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0)
    if not view:
        kernel32.CloseHandle(mapping)
        print(json.dumps({"available": False, "reason": "Unable to map HWiNFO shared memory"}))
        return 3

    try:
        header = Header.from_address(view)
        sensors = []
        for idx in range(header.sensor_count):
            ptr = view + header.sensor_offset + (idx * header.sensor_element_size)
            sensors.append(Sensor.from_address(ptr))

        rows = []
        for idx in range(header.reading_count):
            ptr = view + header.reading_offset + (idx * header.reading_element_size)
            reading = Reading.from_address(ptr)
            if reading.reading_type != SENSOR_TYPE_TEMP:
                continue
            if reading.sensor_index >= len(sensors):
                continue

            sensor = sensors[reading.sensor_index]
            sensor_name = clean(sensor.name_user) or clean(sensor.name_orig)
            label = clean(reading.label_user) or clean(reading.label_orig)
            unit = clean(reading.unit)
            text = f"{sensor_name} {label}"
            if not any(token.lower() in text.lower() for token in ("cpu", "processor", "core", "package", "tctl", "tdie", "intel", "amd", "ryzen")):
                continue
            if unit and unit.upper() not in ("C", "°C"):
                continue
            rows.append(
                {
                    "sensor": sensor_name,
                    "label": label,
                    "value": float(reading.value),
                    "max": float(reading.value_max),
                }
            )

        if not rows:
            print(json.dumps({"available": False, "reason": "No CPU temperature rows found in HWiNFO shared memory"}))
            return 4

        current = round(max(row["value"] for row in rows), 1)
        highest = round(max(row["max"] for row in rows), 1)
        print(
            json.dumps(
                {
                    "available": True,
                    "current_c": current,
                    "current_f": round((current * 9 / 5) + 32, 1),
                    "highest_c": highest,
                    "highest_f": round((highest * 9 / 5) + 32, 1),
                    "status": status_for(highest),
                    "source": "Python HWiNFO Shared Memory",
                    "sensor_count": len(rows),
                }
            )
        )
        return 0
    finally:
        kernel32.UnmapViewOfFile(view)
        kernel32.CloseHandle(mapping)


if __name__ == "__main__":
    if sys.platform != "win32":
        print(json.dumps({"available": False, "reason": "Windows required"}))
        raise SystemExit(1)
    raise SystemExit(main())
