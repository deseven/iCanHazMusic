#pragma once

namespace APE
{

/**************************************************************************************************
CSmartPtr - a simple smart pointer class that can automatically initialize and free memory
    note: (doesn't do garbage collection / reference counting because of the many pitfalls)
**************************************************************************************************/
template <class TYPE> class CSmartPtr
{
public:
    TYPE * m_pObject;
    bool m_bArray;
    bool m_bDelete;

    APE_INLINE CSmartPtr()
    {
        m_bDelete = true;
        m_pObject = APE_NULL;
        m_bArray = false;
    }
    APE_INLINE explicit CSmartPtr(TYPE * pObject, bool bArray = false, bool bDelete = true)
    {
        m_bDelete = true;
        m_pObject = APE_NULL;
        m_bArray = false;
        Assign(pObject, bArray, bDelete);
    }
    APE_INLINE explicit CSmartPtr(int64 nElements, bool bEmpty = false)
    {
        m_bDelete = true;
        m_pObject = APE_NULL;
        m_bArray = false;
        AllocateArray(nElements, bEmpty);
    }

    APE_INLINE ~CSmartPtr()
    {
        Delete();
    }

    APE_INLINE void Assign(TYPE * pObject, bool bArray = false, bool bDelete = true)
    {
        Delete();

        m_bDelete = bDelete;
        m_bArray = bArray;
        m_pObject = pObject;
    }

    APE_INLINE void AllocateArray(int64 nElements, bool bEmpty = false)
    {
        Delete();

        Assign(new TYPE [static_cast<size_t>(nElements)], true);

        if (bEmpty)
        {
            memset(GetPtr(), 0, static_cast<size_t>(nElements) * sizeof(TYPE));
        }
    }

    APE_INLINE void Delete()
    {
        if (m_pObject)
        {
            TYPE * pObject = m_pObject;
            m_pObject = APE_NULL;

            if (m_bDelete)
            {
                if (m_bArray)
                    delete [] pObject;
                else
                    delete pObject;
            }
        }
    }

    void SetDelete(const bool bDelete)
    {
        m_bDelete = bDelete;
    }

    APE_INLINE TYPE * GetPtr() const
    {
        return m_pObject;
    }

    APE_INLINE operator TYPE * () const
    {
        return m_pObject;
    }

    APE_INLINE TYPE * operator ->() const
    {
        return m_pObject;
    }

private:
    // declare assignment, but mark it private so it can't be used
    // that way we can't carelessly mix smart pointers and regular pointers
    APE_INLINE void * operator =(void *) const { return APE_NULL; }
};

}
