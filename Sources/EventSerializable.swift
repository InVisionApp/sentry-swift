//
//  EventSerializable.swift
//  SentrySwift
//
//  Created by Josh Holtz on 12/22/15.
//
//

import Foundation

typealias SerializedTypeDictionary = [String: AnyType]
typealias SerializedTypeArray = [SerializedTypeDictionary]
typealias Attribute = (key: String, value: AnyType?)

/// A protocol used for complex structures (ex: Event, User)
/// on how to serialize them.
protocol EventSerializable {
    associatedtype SerializedType
    var serialized: SerializedType { get }
}

func convertAttributes(_ attributes: [Attribute]) -> SerializedTypeDictionary {
    var ret: SerializedTypeDictionary = [:]
    attributes.filter() { $0.value != nil }.forEach() { ret.updateValue($0.value!, forKey: $0.key) }
    return ret
}
