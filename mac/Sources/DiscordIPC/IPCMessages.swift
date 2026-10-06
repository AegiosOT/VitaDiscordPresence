/// The HANDSHAKE payload: `{"v":1,"client_id":…}`.
struct HandshakePayload: Encodable {
    var v = 1
    var clientID: String

    enum CodingKeys: String, CodingKey {
        case v
        case clientID = "client_id"
    }
}

/// `{"cmd":"SET_ACTIVITY","args":{"pid":…,"activity":…},"nonce":…}`. A `nil` activity is encoded as
/// `null`. Omitting the key does not clear the presence: Discord keeps "Playing" plus the application name.
struct SetActivityCommand: Encodable {
    struct Arguments: Encodable {
        var pid: Int32
        var activity: DiscordActivity?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pid, forKey: .pid)
            if let activity {
                try container.encode(activity, forKey: .activity)
            } else {
                try container.encodeNil(forKey: .activity)
            }
        }

        enum CodingKeys: String, CodingKey {
            case pid, activity
        }
    }

    var cmd = "SET_ACTIVITY"
    var args: Arguments
    var nonce: String
}

/// The fields of an incoming FRAME that the client acts on. Decoding is lenient: a field that is missing or
/// has an unexpected type is `nil`, so only a payload that isn't a JSON object fails.
struct IncomingMessage: Decodable {
    var cmd: String?
    var evt: String?
    var nonce: String?
    var data: Payload?

    /// `data` of READY (`user`) and of ERROR replies (`code`, `message`).
    struct Payload: Decodable {
        var user: DiscordUser?
        var code: Int?
        var message: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            user = try? container.decodeIfPresent(DiscordUser.self, forKey: .user)
            code = try? container.decodeIfPresent(Int.self, forKey: .code)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
        }

        enum CodingKeys: String, CodingKey {
            case user, code, message
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cmd = try? container.decodeIfPresent(String.self, forKey: .cmd)
        evt = try? container.decodeIfPresent(String.self, forKey: .evt)
        nonce = try? container.decodeIfPresent(String.self, forKey: .nonce)
        data = try? container.decodeIfPresent(Payload.self, forKey: .data)
    }

    enum CodingKeys: String, CodingKey {
        case cmd, evt, nonce, data
    }
}

/// The payload of a CLOSE frame: `{"code":…,"message":…}`.
struct ClosePayload: Decodable {
    var code: Int?
    var message: String?
}
