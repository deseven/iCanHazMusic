#pragma once

namespace APE
{

template <class INTTYPE, int MULTIPLY, int SHIFT> class CScaledFirstOrderFilter
{
public:
    CScaledFirstOrderFilter()
    {
        // initialize (to avoid warnings)
        m_nLastValue = 0;
    }

    APE_INLINE void Flush()
    {
        m_nLastValue = 0;
    }

    APE_INLINE INTTYPE Compress(const int32 nInput)
    {
        INTTYPE nResult = static_cast<INTTYPE>(nInput) - ((static_cast<INTTYPE>(m_nLastValue) * MULTIPLY) >> SHIFT);
        m_nLastValue = nInput;
        return nResult;
    }

    APE_INLINE int32 Decompress(const INTTYPE nInput)
    {
        m_nLastValue = static_cast<int32>(nInput + ((static_cast<INTTYPE>(m_nLastValue) * MULTIPLY) >> SHIFT));
        return m_nLastValue;
    }

protected:
    int32 m_nLastValue;
};

}
