import Foundation

// Solar schedule math: a verbatim port of the upstream daemon's suncalc.go
// (itself wlsunset's algorithm) - Fourier-series declination and equation of
// time, sunrise/sunset at solar elevation +3° and civil twilight at -6°,
// with the same polar-day/night clamps. Pure, so the selftest can pin it.
enum Solar {
    static let degToRad = Double.pi / 180.0
    static let radToDeg = 180.0 / Double.pi

    enum Condition {
        case normal
        case midnightSun
        case polarNight
    }

    struct SunTimes: Equatable {
        var dawn: Date
        var sunrise: Date
        var sunset: Date
        var night: Date
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func daysInYear(_ year: Int) -> Int {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 366 : 365
    }

    static func dateOrbitAngle(_ date: Date) -> Double {
        let calendar = utcCalendar
        let year = calendar.component(.year, from: date)
        let yearDay = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        return 2 * Double.pi / Double(daysInYear(year)) * Double(yearDay - 1)
    }

    static func equationOfTime(_ orbitAngle: Double) -> Double {
        4
            * (0.000075 + 0.001868 * cos(orbitAngle) - 0.032077 * sin(orbitAngle)
                - 0.014615 * cos(2 * orbitAngle) - 0.040849 * sin(2 * orbitAngle))
    }

    static func sunDeclination(_ orbitAngle: Double) -> Double {
        0.006918 - 0.399912 * cos(orbitAngle) + 0.070257 * sin(orbitAngle)
            - 0.006758 * cos(2 * orbitAngle) + 0.000907 * sin(2 * orbitAngle)
            - 0.002697 * cos(3 * orbitAngle) + 0.00148 * sin(3 * orbitAngle)
    }

    static func sunHourAngle(latRad: Double, declination: Double, targetSunRad: Double) -> Double {
        acos(
            cos(targetSunRad) / cos(latRad) * cos(declination) - tan(latRad) * tan(declination))
    }

    static func hourAngleToSeconds(_ hourAngle: Double, _ eqtime: Double) -> Double {
        radToDeg * (4.0 * Double.pi - 4 * hourAngle - eqtime) * 60
    }

    static func condition(latRad: Double, declination: Double) -> Condition {
        (latRad >= 0) == (declination >= 0) ? .midnightSun : .polarNight
    }

    static func calculate(
        lat: Double, lon: Double, date: Date, elevTwilight: Double = -6.0,
        elevDaylight: Double = 3.0
    ) -> (times: SunTimes, condition: Condition) {
        let latRad = lat * degToRad
        let elevTwilightRad = (90.833 - elevTwilight) * degToRad
        let elevDaylightRad = (90.833 - elevDaylight) * degToRad

        let orbitAngle = dateOrbitAngle(date)
        let decl = sunDeclination(orbitAngle)
        let eqtime = equationOfTime(orbitAngle)

        let haTwilight = sunHourAngle(latRad: latRad, declination: decl, targetSunRad: elevTwilightRad)
        let haDaylight = sunHourAngle(latRad: latRad, declination: decl, targetSunRad: elevDaylightRad)

        let dayStart = utcCalendar.startOfDay(for: date)

        if haTwilight.isNaN || haDaylight.isNaN {
            let cond = condition(latRad: latRad, declination: decl)
            switch cond {
            case .midnightSun:
                let dayEnd = dayStart.addingTimeInterval(24 * 3600 - 1)
                return (
                    SunTimes(dawn: dayStart, sunrise: dayStart, sunset: dayEnd, night: dayEnd),
                    cond
                )
            default:
                return (
                    SunTimes(dawn: dayStart, sunrise: dayStart, sunset: dayStart, night: dayStart),
                    cond
                )
            }
        }

        let lonOffset = -lon * 4 * 60  // seconds; 4 minutes of time per degree

        let dawnSecs = hourAngleToSeconds(abs(haTwilight), eqtime)
        let sunriseSecs = hourAngleToSeconds(abs(haDaylight), eqtime)
        let sunsetSecs = hourAngleToSeconds(-abs(haDaylight), eqtime)
        let nightSecs = hourAngleToSeconds(-abs(haTwilight), eqtime)

        return (
            SunTimes(
                dawn: dayStart.addingTimeInterval(dawnSecs + lonOffset),
                sunrise: dayStart.addingTimeInterval(sunriseSecs + lonOffset),
                sunset: dayStart.addingTimeInterval(sunsetSecs + lonOffset),
                night: dayStart.addingTimeInterval(nightSecs + lonOffset)),
            .normal
        )
    }

    // Manual-times schedule, upstream rule: dawn/night flank the given
    // sunrise/sunset by the transition duration (default one hour), and a
    // sunset not after sunrise belongs to the next day.
    static func manualTimes(
        sunrise: (hour: Int, minute: Int), sunset: (hour: Int, minute: Int), now: Date,
        transition: TimeInterval = 3600, calendar: Calendar = Calendar.current
    ) -> SunTimes {
        let dayStart = calendar.startOfDay(for: now)
        let sunriseDate = dayStart.addingTimeInterval(
            TimeInterval(sunrise.hour * 3600 + sunrise.minute * 60))
        var sunsetDate = dayStart.addingTimeInterval(
            TimeInterval(sunset.hour * 3600 + sunset.minute * 60))
        if sunsetDate <= sunriseDate { sunsetDate.addTimeInterval(24 * 3600) }
        return SunTimes(
            dawn: sunriseDate.addingTimeInterval(-transition),
            sunrise: sunriseDate,
            sunset: sunsetDate,
            night: sunsetDate.addingTimeInterval(transition))
    }

    // Sun position 0..1, upstream's getSunPositionNormal: 0 through the
    // night, a linear ramp dawn->sunrise, 1 through the day, and a linear
    // ramp back sunset->night. The temperature follows this directly, which
    // is what makes the transitions gradual.
    static func position(now: Date, times: SunTimes) -> Double {
        if now < times.dawn { return 0.0 }
        if now < times.sunrise { return interpolate(now: now, start: times.dawn, stop: times.sunrise) }
        if now < times.sunset { return 1.0 }
        if now < times.night { return interpolate(now: now, start: times.night, stop: times.sunset) }
        return 0.0
    }

    static func interpolate(now: Date, start: Date, stop: Date) -> Double {
        guard start != stop else { return 1.0 }
        let pos = now.timeIntervalSince(start) / stop.timeIntervalSince(start)
        return min(1.0, max(0.0, pos))
    }

    // temp = low + (high-low) * position, upstream's getTempFromPosition.
    static func temperature(position: Double, low: Double, high: Double) -> Int {
        Int(low + (high - low) * position)
    }
}
