import Foundation

/// Three-state field of an ACP v2 upsert update.
///
/// v2 updates patch stored entities: an omitted field leaves the stored
/// value unchanged, `null` clears it, and a concrete value replaces it. A
/// plain optional cannot tell omission from `null`, so patch fields use
/// this type instead.
public enum ACPPatch<Value: Sendable>: Sendable {
  /// The field was omitted: keep the stored value.
  case unchanged
  /// The field was `null`: clear the stored value.
  case clear
  /// The field carried a value: replace the stored value.
  case set(Value)

  /// The concrete value, when this patch sets one.
  public var value: Value? {
    if case .set(let value) = self { return value }
    return nil
  }

  /// Applies this patch to a stored value.
  public func apply(to stored: inout Value?) {
    switch self {
    case .unchanged: break
    case .clear: stored = nil
    case .set(let value): stored = value
    }
  }
}

extension ACPPatch: Equatable where Value: Equatable {}

extension ACPPatch where Value == ACPJSONValue {
  /// Applies a top-level `_meta` patch by key (ACP v2 "metadata patches"):
  /// omitted keeps the stored metadata, `null` clears it, and an object
  /// patches it key by key, where a key set to `null` is removed and any
  /// other value replaces that key whole.
  public func applyMetadata(to stored: inout [String: ACPJSONValue]?) {
    switch self {
    case .unchanged:
      break
    case .clear:
      stored = nil
    case .set(let value):
      guard let patch = value.objectValue else { return }
      var merged = stored ?? [:]
      for (key, entry) in patch {
        if entry == .null {
          merged[key] = nil
        } else {
          merged[key] = entry
        }
      }
      stored = merged
    }
  }
}

extension KeyedDecodingContainer {
  /// Decodes a patch field. A present value that fails to decode is treated
  /// as omitted, matching the schema's default-on-error rule for patch fields.
  func decodePatch<T: Decodable & Sendable>(_ type: T.Type, forKey key: Key) -> ACPPatch<T> {
    guard contains(key) else { return .unchanged }
    if (try? decodeNil(forKey: key)) == true { return .clear }
    guard let value = try? decode(T.self, forKey: key) else { return .unchanged }
    return .set(value)
  }

  /// Decodes an optional field, falling back to `nil` when the value is
  /// malformed (the schema's default-on-error rule).
  func decodeLenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
    guard contains(key) else { return nil }
    return try? decodeIfPresent(T.self, forKey: key)
  }

  /// Decodes an array, dropping items that fail to decode (the schema's
  /// skip-invalid-items rule). Returns `nil` when the field is absent,
  /// `null`, or not an array.
  func decodeLenientArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
    guard contains(key), let items = try? decode([ACPLenientItem<T>].self, forKey: key) else { return nil }
    return items.compactMap(\.value)
  }

  /// Patch variant of `decodeLenientArray`: `[]` and `null` both decode as
  /// they were sent so callers can apply clear semantics.
  func decodePatchArray<T: Decodable & Sendable>(_ type: T.Type, forKey key: Key) -> ACPPatch<[T]> {
    guard contains(key) else { return .unchanged }
    if (try? decodeNil(forKey: key)) == true { return .clear }
    guard let items = decodeLenientArray(T.self, forKey: key) else { return .unchanged }
    return .set(items)
  }
}

extension KeyedEncodingContainer {
  mutating func encodePatch<T: Encodable & Sendable>(_ patch: ACPPatch<T>, forKey key: Key) throws {
    switch patch {
    case .unchanged: break
    case .clear: try encodeNil(forKey: key)
    case .set(let value): try encode(value, forKey: key)
    }
  }
}

/// Decodes one array element, recording failure instead of throwing.
struct ACPLenientItem<T: Decodable>: Decodable {
  let value: T?

  init(from decoder: any Decoder) throws {
    value = try? T(from: decoder)
  }
}

/// Coding key for string-keyed containers whose keys are not known statically.
struct ACPDynamicKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }

  init(_ string: String) {
    stringValue = string
  }

  init?(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue: Int) {
    nil
  }
}

/// Object-valued support marker (`{}`): presence means supported, absence
/// or `null` means unsupported. ACP v2 uses these instead of booleans so a
/// capability can grow fields without a breaking change.
public struct ACPSupportMarker: Codable, Equatable, Sendable {
  public var meta: ACPJSONValue?

  public init(meta: ACPJSONValue? = nil) {
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case meta = "_meta"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    meta = container.decodeLenient(ACPJSONValue.self, forKey: .meta)
  }
}
