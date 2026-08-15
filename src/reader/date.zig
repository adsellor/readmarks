const std = @import("std");

pub fn parse(source: []const u8) ?i64 {
    const value = std.mem.trim(u8, source, " \t\r\n");
    if (value.len < 10) return null;
    if (value.len > 4 and value[4] == '-') return parse_rfc3339(value);
    return parse_rfc822(value);
}

fn parse_rfc3339(value: []const u8) ?i64 {
    if (value.len < 19) return null;
    const year = parse_number(value[0..4]) orelse return null;
    const month = parse_number(value[5..7]) orelse return null;
    const day = parse_number(value[8..10]) orelse return null;
    const hour = parse_number(value[11..13]) orelse return null;
    const minute = parse_number(value[14..16]) orelse return null;
    const second = parse_number(value[17..19]) orelse return null;
    var zone_start: usize = 19;
    if (zone_start < value.len and value[zone_start] == '.') {
        zone_start += 1;
        while (zone_start < value.len) : (zone_start += 1) {
            if (!std.ascii.isDigit(value[zone_start])) break;
        }
    }
    const zone = timezone_offset(value[zone_start..]) orelse return null;
    return timestamp(year, month, day, hour, minute, second, zone);
}

fn parse_rfc822(value: []const u8) ?i64 {
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var first = tokens.next() orelse return null;
    if (first[first.len - 1] == ',') first = tokens.next() orelse return null;
    const month_name = tokens.next() orelse return null;
    const year_value = tokens.next() orelse return null;
    const time_value = tokens.next() orelse return null;
    const zone_value = tokens.next() orelse "GMT";
    const day = parse_number(first) orelse return null;
    const month = month_number(month_name) orelse return null;
    const year = parse_number(year_value) orelse return null;
    const parsed_time = parse_time(time_value) orelse return null;
    const zone = timezone_offset(zone_value) orelse return null;
    return timestamp(
        year,
        month,
        day,
        parsed_time.hour,
        parsed_time.minute,
        parsed_time.second,
        zone,
    );
}

const Time = struct {
    hour: i64,
    minute: i64,
    second: i64,
};

fn parse_time(value: []const u8) ?Time {
    if (value.len < 5) return null;
    if (value[2] != ':') return null;
    const hour = parse_number(value[0..2]) orelse return null;
    const minute = parse_number(value[3..5]) orelse return null;
    const second = if (value.len >= 8 and value[5] == ':')
        parse_number(value[6..8]) orelse return null
    else
        0;
    return .{ .hour = hour, .minute = minute, .second = second };
}

fn timezone_offset(value: []const u8) ?i64 {
    if (value.len == 0) return 0;
    if (std.ascii.eqlIgnoreCase(value, "Z")) return 0;
    if (std.ascii.eqlIgnoreCase(value, "GMT")) return 0;
    if (std.ascii.eqlIgnoreCase(value, "UTC")) return 0;
    if (value[0] != '+' and value[0] != '-') return named_timezone(value);
    if (value.len == 6 and value[3] == ':') {
        const hours = parse_number(value[1..3]) orelse return null;
        const minutes = parse_number(value[4..6]) orelse return null;
        if (hours > 23 or minutes > 59) return null;
        const offset = hours * 3_600 + minutes * 60;
        return if (value[0] == '-') -offset else offset;
    }
    return parse_compact_timezone(value);
}

fn parse_compact_timezone(value: []const u8) ?i64 {
    if (value.len != 5) return null;
    const hours = parse_number(value[1..3]) orelse return null;
    const minutes = parse_number(value[3..5]) orelse return null;
    if (hours > 23 or minutes > 59) return null;
    const offset = hours * 3_600 + minutes * 60;
    return if (value[0] == '-') -offset else offset;
}

fn named_timezone(value: []const u8) ?i64 {
    const zones = [_]struct { name: []const u8, offset: i64 }{
        .{ .name = "EST", .offset = -5 * 3_600 },
        .{ .name = "EDT", .offset = -4 * 3_600 },
        .{ .name = "CST", .offset = -6 * 3_600 },
        .{ .name = "CDT", .offset = -5 * 3_600 },
        .{ .name = "MST", .offset = -7 * 3_600 },
        .{ .name = "MDT", .offset = -6 * 3_600 },
        .{ .name = "PST", .offset = -8 * 3_600 },
        .{ .name = "PDT", .offset = -7 * 3_600 },
    };
    for (zones) |zone| {
        if (std.ascii.eqlIgnoreCase(value, zone.name)) return zone.offset;
    }
    return null;
}

fn timestamp(
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    zone_offset: i64,
) ?i64 {
    if (!valid_date(year, month, day)) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    const days = days_from_civil(year, month, day);
    return days * 86_400 + hour * 3_600 + minute * 60 + second - zone_offset;
}

fn valid_date(year: i64, month: i64, day: i64) bool {
    if (year < 1 or month < 1 or month > 12 or day < 1) return false;
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var maximum = days[@intCast(month - 1)];
    if (month == 2 and is_leap_year(year)) maximum = 29;
    return day <= maximum;
}

fn is_leap_year(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn days_from_civil(year_input: i64, month: i64, day: i64) i64 {
    const year = year_input - @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const adjusted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 +
        @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) +
        day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

fn month_number(value: []const u8) ?i64 {
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    for (months, 0..) |name, index| {
        if (std.ascii.eqlIgnoreCase(value, name)) return @intCast(index + 1);
    }
    return null;
}

fn parse_number(value: []const u8) ?i64 {
    if (value.len == 0) return null;
    return std.fmt.parseInt(i64, value, 10) catch null;
}

test "RFC 822 and RFC 3339 dates normalize to one timestamp" {
    const rfc822 = parse("Thu, 30 Jul 2026 10:00:00 GMT");
    const rfc3339 = parse("2026-07-30T12:00:00+0200");
    try std.testing.expectEqual(rfc822, rfc3339);
    try std.testing.expect(rfc822 != null);
}

test "date parser validates leap days and timezone offsets" {
    try std.testing.expect(parse("2024-02-29T00:00:00Z") != null);
    try std.testing.expect(parse("2023-02-29T00:00:00Z") == null);
    const utc = parse("2026-07-30T10:00:00Z").?;
    const eastern = parse("Thu, 30 Jul 2026 06:00:00 EDT").?;
    try std.testing.expectEqual(utc, eastern);
}
