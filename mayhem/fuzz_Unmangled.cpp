#include <stdint.h>
#include <stdio.h>
#include <climits>
#include <iostream>

#include <fuzzer/FuzzedDataProvider.h>

#include <list>
#include "Unmangler.h"
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    FuzzedDataProvider provider(data, size);
    std::string str = provider.ConsumeRandomLengthString();
    bool warn = provider.ConsumeBool();

    chap::CPlusPlus::Unmangler<char> um(str.c_str(), warn);
    um.Unmangled();

    return 0;
}