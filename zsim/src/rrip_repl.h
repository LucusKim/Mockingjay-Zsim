#ifndef RRIP_REPL_H_
#define RRIP_REPL_H_

#include "repl_policies.h"

// Static RRIP
class SRRIPReplPolicy : public ReplPolicy {
    protected:
        // add class member variables here
        uint32_t* rrpv; // the array of RRPV values
        uint32_t numLines;
        uint32_t rpvMax; //is 3, hardcoded into init.cpp
        bool* justInserted; //determines in replaced if line just inserted

    public:
        // add member methods here, refer to repl_policies.h
            SRRIPReplPolicy(uint32_t _numLines, uint32_t _rpvMax): numLines(_numLines), rpvMax(_rpvMax) {
                rrpv = gm_calloc<uint32_t>(numLines);
                for (uint32_t i = 0; i < numLines; i++) {                                                                                                                                                                                          
                    rrpv[i] = rpvMax;                                                                                                                                                                                                              
                }   
                justInserted = gm_calloc<bool>(numLines); //alr initialized to 0
            }
            ~SRRIPReplPolicy(){
                gm_free(rrpv);
                gm_free(justInserted);
            }
            virtual void replaced(uint32_t id){
                justInserted[id] = true; //slot evicted, next update call is post-insert
            }
            virtual void update(uint32_t id, const MemReq* req){
                if(justInserted[id]){
                    rrpv[id] = rpvMax - 1;
                    justInserted[id] = false;
                }
                else{
                    rrpv[id] = 0; //hit priority
                }
            }
            template <typename C> inline uint32_t rank(const MemReq* req, C cands){
                while(true){
                    //scan for rpvMax, return if found
                    for (auto ci = cands.begin(); ci != cands.end(); ci.inc()) {
                        if(rrpv[*ci] == rpvMax){
                            return *ci;
                        }
                    }
                    //if none found, increment rrpv
                    for (auto id = cands.begin(); id != cands.end(); id.inc()) {                                                                                                                                                                                          
                        rrpv[*id] += 1;                                                                                                                                                                                                              
                    }
                }
            }
            
    
        // DECL_RANK_BINDINGS;
         DECL_RANK_BINDINGS; 
};      
#endif // RRIP_REPL_H_
