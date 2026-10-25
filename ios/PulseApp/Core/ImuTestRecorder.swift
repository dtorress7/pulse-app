import Foundation

/// Grabación temporal del acelerómetro y giroscopio crudos (25/10) para afinar el contador de pasos con pruebas guiadas.
/// imu_prueba.csv: una línea por muestra (100 por segundo) "ms unix,ax,ay,az (g),gx,gy,gz (°/s)". 15 min ≈ 4 MB.
/// Solo graba mientras dura la prueba; el resto del tiempo no hace nada.
enum ImuTestRecorder {
    static let fileName = "imu_prueba.csv"
    private static let key = "pulseapp_imu_test_until"
    private static let queue = DispatchQueue(label: "pulseapp.imutest")

    static var untilMillis: Int64 { return Int64(UserDefaults.standard.double(forKey: key)) }
    static var isRecording: Bool { return TimeUtil.nowMillis() < untilMillis }

    static func start(minutes: Int) {
        let url = AppPaths.file(fileName)
        queue.sync {
            try? "ms,ax,ay,az,gx,gy,gz\n".write(to: url, atomically: true, encoding: .utf8)
        }
        UserDefaults.standard.set(Double(TimeUtil.nowMillis() + Int64(minutes) * 60_000), forKey: key)
    }

    static func stop() { UserDefaults.standard.set(0.0, forKey: key) }

    static func append(_ s: ImuSecond) {
        if !isRecording { return }
        var text = ""
        text.reserveCapacity(s.size * 48)
        let base = s.unixTime * 1000
        for i in 0..<s.size {
            func f(_ v: Float, _ d: Int) -> String { return v.isNaN ? "" : String(format: "%.\(d)f", v) }
            text += "\(base + Int64(i * 10)),\(f(s.ax[i], 4)),\(f(s.ay[i], 4)),\(f(s.az[i], 4)),\(f(s.gx[i], 1)),\(f(s.gy[i], 1)),\(f(s.gz[i], 1))\n"
        }
        let url = AppPaths.file(fileName)
        queue.async {
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        }
    }
}
