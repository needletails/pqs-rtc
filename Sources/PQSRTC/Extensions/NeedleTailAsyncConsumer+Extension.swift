//
//  NeedleTailAsyncConsumer+Extension.swift
//  pqs-rtc
//
//  Created by Cole M on 1/19/26.
//
import NeedleTailAsyncSequence

extension NeedleTailAsyncConsumer {
    func removeAll() async {
        deque.removeAll()
    }
}

