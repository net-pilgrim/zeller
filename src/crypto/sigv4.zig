const std = @import("std");

pub const SigV4 = struct {
    pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![64]u8 {
        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &hash_bytes, .{});
        _ = allocator;
        var hex_out: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_out, "{s}", .{std.fmt.fmtSliceHexLower(&hash_bytes)}) catch unreachable;
        return hex_out;
    }

    pub fn hmacSha256(key: []const u8, data: []const u8) [32]u8 {
        var out: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&out, data, key);
        return out;
    }

    pub const DateInfo = struct {
        amz_date: [16]u8, // YYYYMMDDTHHMMSSZ
        date_stamp: [8]u8, // YYYYMMDD
    };

    pub fn getDates(timestamp: i64) DateInfo {
        const secs: u64 = if (timestamp > 0) @intCast(timestamp) else 0;
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
        const day = epoch_seconds.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        const hours = day_seconds.getHoursIntoDay();
        const minutes = day_seconds.getMinutesIntoHour();
        const seconds = day_seconds.getSecondsIntoMinute();

        var amz_date: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&amz_date, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            hours,
            minutes,
            seconds,
        }) catch unreachable;

        var date_stamp: [8]u8 = undefined;
        @memcpy(&date_stamp, amz_date[0..8]);

        return .{
            .amz_date = amz_date,
            .date_stamp = date_stamp,
        };
    }

    pub fn buildAuthHeader(
        allocator: std.mem.Allocator,
        access_key: []const u8,
        secret_key: []const u8,
        region: []const u8,
        service: []const u8,
        host: []const u8,
        amz_target: []const u8,
        payload: []const u8,
        dates: DateInfo,
    ) ![]const u8 {
        const payload_hash = try sha256Hex(allocator, payload);

        // 1. Canonical request
        // Headers in alphabetical order:
        // content-type, host, x-amz-date, x-amz-target
        const canonical_headers = try std.fmt.allocPrint(
            allocator,
            "content-type:application/x-amz-json-1.1\nhost:{s}\nx-amz-date:{s}\nx-amz-target:{s}\n",
            .{ host, &dates.amz_date, amz_target },
        );
        defer allocator.free(canonical_headers);

        const signed_headers = "content-type;host;x-amz-date;x-amz-target";

        const canonical_request = try std.fmt.allocPrint(
            allocator,
            "POST\n/\n\n{s}\n{s}\n{s}",
            .{ canonical_headers, signed_headers, &payload_hash },
        );
        defer allocator.free(canonical_request);

        const canonical_request_hash = try sha256Hex(allocator, canonical_request);

        // 2. String to sign
        const credential_scope = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}/aws4_request",
            .{ &dates.date_stamp, region, service },
        );
        defer allocator.free(credential_scope);

        const string_to_sign = try std.fmt.allocPrint(
            allocator,
            "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}",
            .{ &dates.amz_date, credential_scope, &canonical_request_hash },
        );
        defer allocator.free(string_to_sign);

        // 3. Derive signing key
        const k_secret = try std.fmt.allocPrint(allocator, "AWS4{s}", .{secret_key});
        defer allocator.free(k_secret);

        const k_date = hmacSha256(k_secret, &dates.date_stamp);
        const k_region = hmacSha256(&k_date, region);
        const k_service = hmacSha256(&k_region, service);
        const k_signing = hmacSha256(&k_service, "aws4_request");

        // 4. Calculate signature
        const signature_bytes = hmacSha256(&k_signing, string_to_sign);
        var signature_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&signature_hex, "{s}", .{std.fmt.fmtSliceHexLower(&signature_bytes)}) catch unreachable;

        // 5. Construct Authorization header
        return try std.fmt.allocPrint(
            allocator,
            "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
            .{ access_key, credential_scope, signed_headers, &signature_hex },
        );
    }
};

test "sigv4 date formatting" {
    const dates = SigV4.getDates(1700000000);
    try std.testing.expectEqualStrings("20231114T221320Z", &dates.amz_date);
    try std.testing.expectEqualStrings("20231114", &dates.date_stamp);
}

test "sigv4 build auth header" {
    const allocator = std.testing.allocator;
    const dates = SigV4.getDates(1700000000);
    const auth = try SigV4.buildAuthHeader(
        allocator,
        "AKIAIOSFODNN7EXAMPLE",
        "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "us-east-1",
        "ssm",
        "ssm.us-east-1.amazonaws.com",
        "AmazonSSM.GetParametersByPath",
        "{}",
        dates,
    );
    defer allocator.free(auth);

    try std.testing.expect(std.mem.startsWith(u8, auth, "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20231114/us-east-1/ssm/aws4_request"));
    try std.testing.expect(std.mem.indexOf(u8, auth, "SignedHeaders=content-type;host;x-amz-date;x-amz-target") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth, "Signature=") != null);
}
