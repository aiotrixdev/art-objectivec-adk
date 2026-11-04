#ifndef ARTADK_AGENTIC_ARTEXECUTIONREFERENCE_H
#define ARTADK_AGENTIC_ARTEXECUTIONREFERENCE_H

#pragma once

//
//  ARTExecutionReference.h
//  ADK
//
//  Agent and orchestrator ids are execution references: the slug the server
//  routes on, optionally pinned to a named build.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Checks that `reference` names an agent or orchestrator the way the server
/// routes it: a lowercase slug (`my-agent`), optionally pinned to a named
/// build (`my-agent@release2`). Build names are 1–64 lowercase letters or
/// digits.
///
/// Returns `reference` unchanged; it is never normalised. Returns nil and
/// sets `error` (`ErrorCodeInvalidArgument`) otherwise.
FOUNDATION_EXPORT NSString *_Nullable ARTValidateExecutionReference(
    NSString *reference, NSError **error);

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AGENTIC_ARTEXECUTIONREFERENCE_H */
